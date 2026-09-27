import { useCallback, useEffect, useRef, useState } from 'react';
import * as api from '../../services/api.js';
import { useProjectContext } from '../../context/ProjectContext.jsx';
import { useNativeDialogs } from '../../hooks/useNativeDialogs.js';

/** @typedef {import('../../types.js').SelectedTests} SelectedTests */

const DEFAULT_TESTS = {
  tTest: true,
  anova: true,
  correlation: true,
  multipleComparisons: true,
  nonParametric: true,
  fisherVariance: true,
  correlationMatrix: true,
  zVariance: true,
};

/** Grupos mínimos requeridos por cada prueba, y su nombre para mensajes al usuario. */
const REQUISITOS = {
  tTest: { minGrupos: 2, nombre: 'Prueba T de Student' },
  anova: { minGrupos: 3, nombre: 'ANOVA / ANCOVA' },
  correlation: { minGrupos: 2, nombre: 'Test de Correlación' },
  multipleComparisons: { minGrupos: 3, nombre: 'Comparaciones Múltiples' },
  nonParametric: { minGrupos: 2, nombre: 'Pruebas No Paramétricas' },
  fisherVariance: { minGrupos: 2, nombre: 'Prueba F de Fisher' },
  correlationMatrix: { minGrupos: 2, nombre: 'Matriz de Correlación' },
  zVariance: { minGrupos: 2, nombre: 'Prueba Z de Varianzas' },
};

export function useStatistics() {
  const { activeTab, selectedFiles, selectedFolders, preselectFirstLevelFolders, project } = useProjectContext();
  const { notify } = useNativeDialogs();

  const [statisticsRunning, setStatisticsRunning] = useState(false);
  const [statisticsResults, setStatisticsResults] = useState(null);
  const [compareByFiles, setCompareByFiles] = useState(true);
  const [selectedTests, setSelectedTests] = useState(DEFAULT_TESTS);

  // Al activarse la pestaña, pre-seleccionar carpetas de primer nivel
  // (igual que handleTabChange original).
  const wasActive = useRef(false);
  useEffect(() => {
    const isActive = activeTab === 'statistics';
    if (isActive && !wasActive.current) preselectFirstLevelFolders();
    wasActive.current = isActive;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeTab]);

  const toggleTest = useCallback((testKey) => {
    setSelectedTests((prev) => ({ ...prev, [testKey]: !prev[testKey] }));
  }, []);

  const startStatistics = useCallback(async () => {
    if (selectedFiles.length === 0) {
      notify('⚠️  Debes seleccionar archivos de al menos 2 grupos diferentes');
      return;
    }

    setStatisticsRunning(true);
    setStatisticsResults(null);

    try {
      // Agrupar por carpeta padre (estructura esperada: Grupo/archivo).
      const grupos = {};
      let archivosIgnorados = 0;
      let archivosIncorrectos = 0;

      for (const file of selectedFiles) {
        const normalizedPath = file.path.replace(/\\/g, '/');
        const pathParts = normalizedPath.split('/');

        if (pathParts.length < 2) {
          console.warn(`⚠️ ESTRUCTURA INCORRECTA: ${file.name} sin carpeta de grupo`);
          archivosIncorrectos++;
          continue;
        }
        if (pathParts.length > 2) {
          console.warn(`⚠️ IGNORADO: ${file.name} anidado en subcarpetas (${normalizedPath})`);
          archivosIgnorados++;
          continue;
        }

        const nombreGrupo = pathParts[pathParts.length - 2];
        if (!grupos[nombreGrupo]) grupos[nombreGrupo] = [];
        // `fullPath` (ruta absoluta dentro del proyecto) en vez de `file.name`:
        // el backend la resuelve directo sin pasar por TEMP_DIR — ver
        // FileResolver.resolver_ruta_archivo en el backend.
        grupos[nombreGrupo].push(file.fullPath || file.name);
      }

      if (archivosIncorrectos > 0) {
        notify(
          `⚠️ Advertencia:\n\n${archivosIncorrectos} archivo(s) no siguen la estructura correcta.\n\nEstructura esperada:\n  Proyecto/Grupo/archivo.nii.gz\n\nEstos archivos fueron ignorados. Revisa la consola (F12) para detalles.`
        );
      }
      if (archivosIgnorados > 0) {
        notify(
          `⚠️ ${archivosIgnorados} archivo(s) fueron ignorados.\n\nMotivo: Están dentro de subcarpetas adicionales.\n\nEstructura esperada:\n  Proyecto/Grupo/archivo.nii.gz\n\nNo use:\n  Proyecto/Grupo/Subcarpeta/archivo.nii.gz`
        );
      }

      const numGrupos = Object.keys(grupos).length;
      if (numGrupos < 2) {
        notify(
          `⚠️  Solo se detectó ${numGrupos} grupo.\n\nPara análisis estadístico necesitas seleccionar archivos de al menos 2 carpetas diferentes.\n\nGrupo encontrado: ${Object.keys(grupos)[0]}`
        );
        setStatisticsRunning(false);
        return;
      }

      // Validar requisitos mínimos de grupos por prueba.
      const pruebasSeleccionadas = Object.keys(selectedTests).filter((key) => selectedTests[key]);
      const pruebasValidas = [];
      const pruebasRechazadas = [];

      for (const prueba of pruebasSeleccionadas) {
        const req = REQUISITOS[prueba];
        if (req && numGrupos < req.minGrupos) {
          pruebasRechazadas.push({ nombre: req.nombre, requiere: req.minGrupos, actual: numGrupos });
        } else {
          pruebasValidas.push(prueba);
        }
      }

      if (pruebasRechazadas.length > 0) {
        const mensaje = pruebasRechazadas
          .map((p) => `• ${p.nombre}: requiere ${p.requiere} grupos (tienes ${p.actual})`)
          .join('\n');
        notify(`⚠️ Algunas pruebas no se pueden realizar:\n\n${mensaje}\n\nLas demás pruebas se ejecutarán normalmente.`);
        console.warn('⚠️ Pruebas rechazadas por falta de grupos:', pruebasRechazadas);
      }

      if (pruebasValidas.length === 0) {
        notify('❌ Ninguna de las pruebas seleccionadas puede realizarse con el número actual de grupos.');
        setStatisticsRunning(false);
        return;
      }

      const pruebasFinales = ['normalityTest', ...pruebasValidas];

      const result = await api.analisisEstadistico({
        grupos,
        pruebas: pruebasFinales,
        comparar_por_archivos: compareByFiles,
        tipo_datos: selectedFiles.some((f) => /\.(xlsx|xls)$/i.test(f.name)) ? 'excel' : 'imagenes',
        ruta_proyecto: project?.ruta || '',
      });

      if (result.success) {
        setStatisticsResults(result.resultados);
        notify('✅ Análisis estadístico completado');
      } else {
        notify(`❌ Error: ${result.error}`);
      }
    } catch (error) {
      console.error('Error:', error);
      notify('Error de conexión con el servidor');
    } finally {
      setStatisticsRunning(false);
    }
  }, [selectedFiles, selectedTests, compareByFiles, project, notify]);

  return {
    statisticsRunning,
    statisticsResults,
    compareByFiles,
    setCompareByFiles,
    selectedTests,
    toggleTest,
    selectedFiles,
    selectedFolders,
    startStatistics,
  };
}
