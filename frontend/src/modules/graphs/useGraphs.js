import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import * as api from '../../services/api.js';
import { useProjectContext } from '../../context/ProjectContext.jsx';
import { useNativeDialogs } from '../../hooks/useNativeDialogs.js';
import { extractAllCompatibleFiles } from '../../utils/fileTree.js';
import { PARAMS_POR_DEFECTO, construirOpciones, descargarArchivo } from './graphUtils.js';

/**
 * Estado y lógica propios de Grafos. Mismo patrón que `useRadiomics`/
 * `useStatistics`: lee `structure`/`selectedFile(s)`/`project` del
 * `ProjectContext` y expone su propio estado, sin tocar los otros módulos.
 *
 * Controles manuales: `params` (textos de los campos), `bbox` (recorte de
 * región, Paso 0) y `opciones` (lo que realmente se envía al backend, derivado
 * de los dos anteriores por `construirOpciones`: solo lo que difiere del
 * default). `erroresParams` impide lanzar el análisis mientras haya algún
 * campo inválido.
 *
 * `tipoGrafo` está fijo en `'vascular'` por ahora (única rama implementada en
 * el backend; `'conectividad'` responde 501). Cuando se implemente la segunda
 * rama, esto se vuelve una selección real en la UI.
 */
export function useGraphs() {
  const { activeTab, structure, selectedFile, selectedFiles, project } = useProjectContext();
  const { notify } = useNativeDialogs();

  const [multipleFilesMode, setMultipleFilesMode] = useState(true);
  const [tipoGrafo] = useState('vascular');
  const [graphsRunning, setGraphsRunning] = useState(false);
  const [graphsResults, setGraphsResults] = useState(null);
  const [expandedResult, setExpandedResult] = useState(null);

  const [params, setParams] = useState(PARAMS_POR_DEFECTO);
  const [bbox, setBbox] = useState(null);
  const [regionAbierta, setRegionAbierta] = useState(false);
  const [exportando, setExportando] = useState(false);

  // Al activarse la pestaña, forzar modo múltiple (igual que en Radiómica).
  const wasActive = useRef(false);
  useEffect(() => {
    const isActive = activeTab === 'graphs';
    if (isActive && !wasActive.current) setMultipleFilesMode(true);
    wasActive.current = isActive;
  }, [activeTab]);

  const filesToAnalyze = multipleFilesMode
    ? selectedFiles.length > 0
      ? selectedFiles
      : extractAllCompatibleFiles(structure || {}, 'graphs')
    : selectedFile
      ? [selectedFile]
      : [];

  const { opciones, errores: erroresParams } = useMemo(() => construirOpciones(params, bbox), [params, bbox]);

  const setParam = useCallback((clave, valor) => {
    setParams((previo) => ({ ...previo, [clave]: valor }));
  }, []);

  const restablecerParams = useCallback(() => setParams(PARAMS_POR_DEFECTO), []);

  const startGraphs = useCallback(async () => {
    if (filesToAnalyze.length === 0) {
      notify('No hay archivos seleccionados');
      return;
    }
    if (erroresParams.length > 0) {
      notify(`Revisa los parámetros:\n${erroresParams.join('\n')}`);
      return;
    }

    setGraphsRunning(true);
    setGraphsResults(null);
    setExpandedResult(null);

    try {
      const result = await api.analisisGrafos({
        archivos: filesToAnalyze.map((f) => f.fullPath || f.name),
        tipo_grafo: tipoGrafo,
        opciones,
        ruta_proyecto: project?.ruta || '',
      });

      if (result.success) {
        setGraphsResults(result.resultados);
        notify(`✅ Análisis completado\n${filesToAnalyze.length} archivo(s) procesado(s)`);
      } else {
        notify(`❌ Error: ${result.error}`);
      }
    } catch (error) {
      console.error('Error:', error);
      notify('Error de conexión');
    } finally {
      setGraphsRunning(false);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [filesToAnalyze, tipoGrafo, opciones, erroresParams, project, notify]);

  /**
   * Exporta los datos de los grafos analizados: "xlsx" (todas las tablas en un libro) o "csv" (una
   * tabla: sujetos, aristas o nodos). El backend los lee de los JSON que guardó el análisis y los
   * devuelve en Base64; acá se dispara la descarga.
   */
  const exportar = useCallback(
    async (formato, tabla = 'sujetos') => {
      const rutas = (graphsResults || []).filter((r) => r.success && r.grafo?.ruta_json).map((r) => r.grafo.ruta_json);
      if (rutas.length === 0) {
        notify('No hay resultados para exportar');
        return;
      }
      setExportando(true);
      try {
        const res = await api.grafosExportar({ rutas_json: rutas, formato, tabla, ruta_proyecto: project?.ruta || '' });
        if (res.success) {
          descargarArchivo(res.nombre, res.mime, res.contenido_base64);
          if (res.omitidos?.length) notify(`Se omitieron ${res.omitidos.length} grafo(s) que no se pudieron leer`);
        } else {
          notify(`❌ Error: ${res.error}`);
        }
      } catch (error) {
        console.error('Error:', error);
        notify('Error de conexión al exportar');
      } finally {
        setExportando(false);
      }
    },
    [graphsResults, project, notify],
  );

  return {
    multipleFilesMode,
    setMultipleFilesMode,
    tipoGrafo,
    graphsRunning,
    graphsResults,
    expandedResult,
    setExpandedResult,
    filesToAnalyze,
    startGraphs,
    structure,
    selectedFiles,
    // controles manuales
    params,
    setParam,
    restablecerParams,
    erroresParams,
    bbox,
    setBbox,
    regionAbierta,
    setRegionAbierta,
    exportando,
    exportar,
  };
}
