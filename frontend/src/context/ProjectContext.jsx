import React, { createContext, useCallback, useContext, useMemo, useState } from 'react';
import * as api from '../services/api.js';
import { useNativeDialogs } from '../hooks/useNativeDialogs.js';
import {
  extractAllCompatibleFiles,
  findFirstCompatibleFile,
  buildTreeFromFiles,
  firstLevelFolders,
} from '../utils/fileTree.js';

/** @typedef {import('../types.js').FileNode} FileNode */

/**
 * "Verdad" compartida del workspace: qué proyecto está abierto, su árbol de
 * archivos, qué pestaña está activa y qué archivos/carpetas están
 * seleccionados en ese árbol. Ningún módulo asume "lo que esté abierto
 * ahora": todos reciben esto explícito vía `useProjectContext()`.
 *
 * Las acciones que hablan con el backend viven aquí porque todas terminan
 * mutando este mismo estado compartido (proyecto/estructura); la única
 * dependencia externa que usan es `services/api.js`.
 */
const ProjectContext = createContext(null);

export function ProjectProvider({ children }) {
  const { promptText, notify } = useNativeDialogs();

  // Proyecto activo — único lugar donde vive este dato (principio 3).
  const [project, setProject] = useState(null); // { id?, nombre, ruta }
  const [structure, setStructure] = useState(null); // FileNode raíz
  const [proyectosGuardados, setProyectosGuardados] = useState([]);

  // Pestaña activa: vive aquí (no en cada módulo) porque la selección de
  // archivos/carpetas depende de ella (compatibilidad NIfTI/DICOM/Excel).
  const [activeTab, setActiveTab] = useState('visualization');

  // Selección compartida por el árbol de archivos (sidebar) y los módulos
  // que necesitan multi-selección (Radiómica, Estadística).
  const [selectedFile, setSelectedFile] = useState(null);
  const [selectedFiles, setSelectedFiles] = useState([]);
  const [selectedFolders, setSelectedFolders] = useState([]);

  // Overlay de carga ("Procesando...") usado por los flujos largos.
  const [busy, setBusy] = useState(false);
  const [busyMessage, setBusyMessage] = useState('');

  const withBusy = useCallback(async (message, fn) => {
    setBusy(true);
    setBusyMessage(message);
    try {
      return await fn();
    } finally {
      setBusy(false);
    }
  }, []);

  // --------------------------------------------------------------------
  // Proyectos guardados (PostgreSQL)
  // --------------------------------------------------------------------

  const refreshProyectosGuardados = useCallback(async () => {
    try {
      const data = await api.listarProyectos();
      setProyectosGuardados(data);
    } catch (error) {
      console.error('❌ Error cargando proyectos:', error);
    }
  }, []);

  const openPersistedProject = useCallback(async (id) => {
    await withBusy('Abriendo proyecto...', async () => {
      try {
        const data = await api.abrirProyectoPersistente(id);
        if (data.success) {
          // Nota: seguimos sin auto-seleccionar ni pre-cargar la primera
          // imagen acá (mismo comportamiento que antes). Ya no es porque
          // fallaría: `load-image`/`get-slice` ahora resuelven `fullPath`
          // directo (ver FileResolver en el backend), así que SÍ
          // funcionaría si se quisiera agregar el auto-preview más
          // adelante — sólo no estaba pedido en este cambio.
          setProject({ id: data.id, nombre: data.nombre, ruta: data.ruta_proyecto });
          setStructure(data.estructura);
        } else {
          notify(`❌ ${data.error}`);
        }
      } catch (error) {
        console.error(error);
        notify('❌ Error abriendo proyecto');
      }
    });
  }, [withBusy, notify]);

  /**
   * Elimina un proyecto guardado (fila en BD + carpeta en disco, vía
   * `DELETE /api/proyecto/:id`).
   */
  const eliminarProyecto = useCallback(async (id) => {
    try {
      const result = await api.eliminarProyecto(id);
      if (result.success) {
        await refreshProyectosGuardados();
        if (result.carpeta_borrada === false) {
          notify('⚠️  El proyecto se quitó de la lista, pero no se pudo borrar su carpeta en disco (revisala manualmente).');
        }
      } else {
        notify(`❌ ${result.error || 'No se pudo eliminar el proyecto'}`);
      }
      return result;
    } catch (error) {
      console.error(error);
      notify('❌ Error de conexión eliminando el proyecto');
      return { success: false };
    }
  }, [notify, refreshProyectosGuardados]);

  /** Renombra un proyecto guardado (carpeta real en disco + fila en la BD). */
  const renombrarProyecto = useCallback(async (id, nuevoNombre) => {
    try {
      const result = await api.renombrarProyecto(id, nuevoNombre);
      if (result.success) {
        await refreshProyectosGuardados();
      } else {
        notify(`❌ ${result.error || 'No se pudo renombrar el proyecto'}`);
      }
      return result;
    } catch (error) {
      console.error(error);
      notify('❌ Error de conexión renombrando el proyecto');
      return { success: false };
    }
  }, [notify, refreshProyectosGuardados]);

  // --------------------------------------------------------------------
  // Abrir proyecto (selector nativo del backend, con fallback al selector
  // del navegador cuando NativeFileDialog no está disponible).
  // --------------------------------------------------------------------

  /**
   * @param {{onFallback: () => void, juliaConnected: boolean}} opts
   */
  const openProjectFromDialog = useCallback(async ({ onFallback, juliaConnected }) => {
    if (!juliaConnected) {
      notify('⚠️  El servidor de Julia no está conectado.\n\nPor favor, inicia server.jl primero.');
      return;
    }

    await withBusy('Abriendo selector de carpetas...', async () => {
      try {
        const result = await api.seleccionarCarpetaLocal();

        if (result.success) {
          setProject({ nombre: result.nombre_proyecto, ruta: result.ruta_proyecto });
          setStructure(result.estructura);

          // Ya no hace falta re-subir los archivos: cada FileNode trae su
          // `fullPath` (ruta absoluta real, dentro del volumen montado), y
          // el backend lo resuelve directo — sin pasar por TEMP_DIR ni por
          // una subida en Base64. Alcanza con seleccionar el primer archivo
          // compatible; `useVisualization` reacciona a ese cambio.
          const allFiles = extractAllCompatibleFiles(result.estructura, 'visualization');
          if (allFiles.length > 0) {
            setSelectedFile(allFiles[0]);
          }
        } else if (result.usar_fallback) {
          console.log('📁 Usando selector de navegador (fallback)');
          onFallback?.();
        } else {
          notify('❌ Error: ' + result.error);
        }
      } catch (error) {
        console.log('📁 Usando selector de navegador', error);
        onFallback?.();
      }
    });
  }, [withBusy, notify]);

  /** Fallback: el usuario eligió una carpeta con el <input webkitdirectory>. */
  const openProjectFromBrowserFileList = useCallback(async (fileList) => {
    if (fileList.length === 0) return;

    await withBusy('Procesando archivos del navegador...', async () => {
      const firstFile = fileList[0];
      const folderName = firstFile.webkitRelativePath.split('/')[0];

      setBusyMessage('Construyendo estructura de carpetas...');
      const tree = buildTreeFromFiles(fileList, folderName, activeTab);
      setStructure(tree);

      setBusyMessage(`Subiendo ${fileList.length} archivos...`);
      for (let i = 0; i < fileList.length; i++) {
        setBusyMessage(`Subiendo ${i + 1}/${fileList.length}: ${fileList[i].name}`);
        await api.uploadFile(fileList[i]);
      }

      // NOTA (bug arreglado): antes acá se intentaba "adivinar" la ruta real
      // del proyecto subiendo el primer archivo y leyendo `absolute_path` de
      // la respuesta. Eso nunca podía funcionar: /api/upload-file guarda
      // TODO archivo subido dentro de TEMP_DIR (/tmp/msl_process_cache),
      // sin importar de dónde vino — así que `absolute_path` siempre caía
      // ahí, y el "proyecto" terminaba apuntando al caché en vez de a la
      // carpeta real. Un navegador no expone la ruta real de una carpeta
      // elegida por el usuario (restricción de seguridad, no es solucionable
      // del lado del frontend), así que ahora se deja la ruta vacía y
      // explícita en vez de mostrar una incorrecta — ver `project.ruta`
      // en WorkspaceHeader para el aviso al usuario, y el README para la
      // solución de fondo (un endpoint del backend para elegir carpetas
      // del propio servidor).
      setProject({ nombre: folderName, ruta: '' });

      const firstCompatible = findFirstCompatibleFile(tree);
      if (firstCompatible) {
        setBusyMessage('Cargando primera imagen...');
        setSelectedFile(firstCompatible);
      }
    });
  }, [withBusy, activeTab]);

  // --------------------------------------------------------------------
  // Crear proyecto / agregar grupos / agregar archivos
  // --------------------------------------------------------------------

  const createProject = useCallback(async ({ juliaConnected }) => {
    if (!juliaConnected) {
      notify('⚠️  El servidor de Julia no está conectado.\n\nPor favor, inicia server.jl primero.');
      return;
    }

    await withBusy('Selecciona dónde crear el proyecto...', async () => {
      const locationResult = await api.seleccionarCarpetaLocal().catch(() => ({ success: false }));
      let ubicacionBase = '';
      if (locationResult.success) {
        ubicacionBase = locationResult.ruta_proyecto;
      } else {
        console.warn('Usando ubicación fallback del backend');
      }

      const nombreProyecto = promptText('Nombre del nuevo proyecto:');
      if (!nombreProyecto) return;

      const numGruposStr = promptText('¿Cuántos grupos crear? (0 para ninguno):', '2');
      const numGrupos = parseInt(numGruposStr, 10) || 0;

      setBusyMessage('Creando proyecto...');
      try {
        const result = await api.crearProyecto({
          ruta_base: ubicacionBase,
          nombre_proyecto: nombreProyecto,
          num_grupos: numGrupos,
        });

        if (result.success) {
          notify(`✅ Proyecto creado:\n${result.ruta_proyecto}\n\nGrupos: ${result.carpetas_creadas.join(', ')}`);
          setProject({ nombre: nombreProyecto, ruta: result.ruta_proyecto });
          setStructure(result.estructura);
          await refreshProyectosGuardados();
        } else {
          notify(`❌ Error: ${result.error}`);
        }
      } catch (error) {
        console.error('Error:', error);
        notify('Error de conexión con el servidor');
      }
    });
  }, [withBusy, notify, promptText, refreshProyectosGuardados]);

  const addGroups = useCallback(async () => {
    if (!project?.ruta) {
      notify(
        '⚠️  No se puede determinar la ruta real de este proyecto (se abrió con el selector del ' +
        'navegador, sin selector nativo disponible). "Agregar grupos" no está disponible hasta ' +
        'reabrirlo de otra forma.'
      );
      return;
    }
    const numGruposStr = promptText('¿Cuántos grupos agregar?', '1');
    const numGrupos = parseInt(numGruposStr, 10) || 0;
    if (numGrupos <= 0) return;

    try {
      const result = await api.agregarGrupos({ ruta_proyecto: project.ruta, num_grupos: numGrupos });
      if (result.success) {
        notify(`✅ Grupos agregados:\n${result.carpetas_creadas.join(', ')}`);
        setStructure(result.estructura);
      } else {
        notify(`❌ Error: ${result.error}`);
      }
    } catch (error) {
      console.error('Error:', error);
      notify('Error de conexión con el servidor');
    }
  }, [project, notify, promptText]);

  const addFiles = useCallback(async ({ fileList, carpetaDestino, nombreBase }) => {
    if (!fileList || fileList.length === 0 || !carpetaDestino || !nombreBase) return;

    await withBusy('Agregando archivos al proyecto...', async () => {
      try {
        const archivos = await Promise.all(
          fileList.map(async (file) => ({
            data: await api.fileToBase64(file),
            extension: extensionFor(file.name),
          }))
        );

        const result = await api.agregarArchivos({
          ruta_proyecto: project.ruta,
          carpeta_destino: carpetaDestino,
          nombre_base: nombreBase,
          num_archivos: fileList.length,
          archivos,
        });

        if (result.success) {
          notify(`✅ ${result.archivos_agregados.length} archivos agregados:\n${result.archivos_agregados.join(', ')}`);
          setStructure(result.estructura);

          setBusyMessage('Sincronizando archivos con servidor...');
          for (let i = 0; i < result.archivos_agregados.length; i++) {
            const nombreArchivo = result.archivos_agregados[i];
            const archivoOriginal = fileList[i];
            setBusyMessage(`Subiendo ${i + 1}/${result.archivos_agregados.length}: ${nombreArchivo}`);
            const archivoRenombrado = new File([archivoOriginal], nombreArchivo, {
              type: archivoOriginal.type,
            });
            await api.uploadFile(archivoRenombrado);
          }
        } else {
          notify(`❌ Error: ${result.error}`);
        }
      } catch (error) {
        console.error('Error:', error);
        notify('Error de conexión');
      }
    });
  }, [project, notify, withBusy]);
  // --------------------------------------------------------------------

  const goHome = useCallback(() => {
    setProject(null);
    setStructure(null);
    setSelectedFile(null);
    setSelectedFiles([]);
    setSelectedFolders([]);
  }, []);

  /** Cambia de pestaña y limpia la selección — igual que el App.js original. */
  const changeTab = useCallback((tab) => {
    setActiveTab(tab);
    setSelectedFiles([]);
    setSelectedFolders([]);
  }, []);

  const selectFile = useCallback((fileNode) => {
    setSelectedFile(fileNode);
  }, []);

  const toggleFileSelection = useCallback((fileNode) => {
    setSelectedFiles((prev) => {
      const isSelected = prev.some((f) => f.path === fileNode.path);
      if (!isSelected) return [...prev, fileNode];

      const newFiles = prev.filter((f) => f.path !== fileNode.path);
      setSelectedFolders((prevFolders) =>
        prevFolders.filter((folder) => {
          if (!fileNode.path.startsWith(folder.path + '/')) return true;
          const allFilesInFolder = extractAllCompatibleFiles(folder, activeTab);
          return allFilesInFolder.every(
            (f) => f.path === fileNode.path || newFiles.some((sf) => sf.path === f.path)
          );
        })
      );
      return newFiles;
    });
  }, [activeTab]);

  const toggleFolderSelection = useCallback((folderNode) => {
    const allFiles = extractAllCompatibleFiles(folderNode, activeTab);
    setSelectedFiles((prev) => {
      const allSelected = allFiles.every((f) => prev.some((sf) => sf.path === f.path));
      if (allSelected) {
        setSelectedFolders((prevFolders) => prevFolders.filter((sf) => sf.path !== folderNode.path));
        return prev.filter((f) => !allFiles.some((af) => af.path === f.path));
      }
      setSelectedFolders((prevFolders) =>
        prevFolders.some((sf) => sf.path === folderNode.path) ? prevFolders : [...prevFolders, folderNode]
      );
      const newFiles = allFiles.filter((f) => !prev.some((pf) => pf.path === f.path));
      return [...prev, ...newFiles];
    });
  }, [activeTab]);

  const selectAllCompatible = useCallback(() => {
    if (!structure) return;
    const allFiles = extractAllCompatibleFiles(structure, activeTab);
    if (selectedFiles.length === allFiles.length) {
      setSelectedFiles([]);
      setSelectedFolders([]);
    } else {
      setSelectedFiles(allFiles);
    }
  }, [structure, activeTab, selectedFiles.length]);

  /** Usado por Estadística al activarse: pre-selecciona carpetas de primer nivel. */
  const preselectFirstLevelFolders = useCallback(() => {
    if (!structure) return;
    setSelectedFolders(firstLevelFolders(structure));
  }, [structure]);

  const value = useMemo(
    () => ({
      project,
      structure,
      hasProject: !!project,
      proyectosGuardados,
      refreshProyectosGuardados,
      openPersistedProject,
      eliminarProyecto,
      renombrarProyecto,
      openProjectFromDialog,
      openProjectFromBrowserFileList,
      createProject,
      addGroups,
      addFiles,
      goHome,
      busy,
      busyMessage,
      activeTab,
      changeTab,
      selectedFile,
      selectedFiles,
      selectedFolders,
      selectFile,
      toggleFileSelection,
      toggleFolderSelection,
      selectAllCompatible,
      preselectFirstLevelFolders,
      setSelectedFiles,
      setSelectedFolders,
    }),
    [
      project, structure, proyectosGuardados, refreshProyectosGuardados, openPersistedProject,
      eliminarProyecto, renombrarProyecto,
      openProjectFromDialog, openProjectFromBrowserFileList, createProject, addGroups, addFiles,
      goHome, busy, busyMessage, activeTab, changeTab, selectedFile, selectedFiles, selectedFolders,
      selectFile, toggleFileSelection, toggleFolderSelection, selectAllCompatible, preselectFirstLevelFolders,
    ]
  );

  return <ProjectContext.Provider value={value}>{children}</ProjectContext.Provider>;
}

export function useProjectContext() {
  const ctx = useContext(ProjectContext);
  if (!ctx) throw new Error('useProjectContext debe usarse dentro de <ProjectProvider>');
  return ctx;
}

function extensionFor(filename) {
  const name = filename.toLowerCase();
  if (name.endsWith('.nii.gz')) return 'nii.gz';
  if (name.endsWith('.nii')) return 'nii';
  if (name.endsWith('.dcm')) return 'dcm';
  if (name.endsWith('.dicom')) return 'dicom';
  return filename.split('.').pop();
}
