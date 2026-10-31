import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import * as api from '../../services/api.js';
import { useProjectContext } from '../../context/ProjectContext.jsx';
import { useNativeDialogs } from '../../hooks/useNativeDialogs.js';
import { extractAllCompatibleFiles } from '../../utils/fileTree.js';
import { sujetosDeResultados } from './comparacionUtils.js';
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
 * Comparación entre grupos (Fase 3B): `sujetosComparables` sale de los resultados del análisis (un sujeto por
 * archivo, con sus 54 características), `comparar(peticion)` llama a /api/grafos/comparar y deja el resultado en
 * `comparacion`, que se descarta al lanzar otro análisis (ya no corresponde a los resultados en pantalla).
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
  const [comparacion, setComparacion] = useState(null);
  const [comparando, setComparando] = useState(false);

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

  const sujetosComparables = useMemo(() => sujetosDeResultados(graphsResults), [graphsResults]);

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
    setComparacion(null);
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
   * Compara los grupos (Fase 3B). `peticion` sale de `construirPeticion` (comparacionUtils.js): sujetos de los
   * grupos elegidos, grupos con la referencia primero, prueba principal y α. Los errores de validación del
   * backend (400) llegan con el motivo y se muestran tal cual.
   */
  const comparar = useCallback(
    async (peticion) => {
      setComparando(true);
      try {
        const res = await api.grafosComparar(peticion);
        if (res.success) {
          setComparacion(res);
        } else {
          notify(`❌ Error: ${res.error}`);
        }
      } catch (error) {
        console.error('Error:', error);
        notify('Error de conexión al comparar');
      } finally {
        setComparando(false);
      }
    },
    [notify],
  );

  /** Pide la exportación y dispara la descarga del archivo (Base64) que devuelve el backend. */
  const pedirExportacion = useCallback(
    async (payload) => {
      setExportando(true);
      try {
        const res = await api.grafosExportar({ ...payload, ruta_proyecto: project?.ruta || '' });
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
    [project, notify],
  );

  /**
   * Exporta los datos de los grafos analizados: "xlsx" (todas las tablas en un libro, con las hojas
   * Comparación/Pares si ya se comparó) o "csv" (una tabla: sujetos, aristas o nodos). El backend los lee de
   * los JSON que guardó el análisis y los devuelve en Base64; acá se dispara la descarga.
   */
  const exportar = useCallback(
    async (formato, tabla = 'sujetos') => {
      const rutas = (graphsResults || []).filter((r) => r.success && r.grafo?.ruta_json).map((r) => r.grafo.ruta_json);
      if (rutas.length === 0) {
        notify('No hay resultados para exportar');
        return;
      }
      await pedirExportacion({ rutas_json: rutas, formato, tabla, ...(formato === 'xlsx' && comparacion ? { comparacion } : {}) });
    },
    [graphsResults, comparacion, pedirExportacion, notify],
  );

  /** Exporta solo la comparación como CSV: tabla "comparacion" (una fila por característica) o "pares" (post-hoc). */
  const exportarComparacion = useCallback(
    async (tabla) => {
      if (!comparacion) {
        notify('Primero compara los grupos');
        return;
      }
      await pedirExportacion({ rutas_json: [], formato: 'csv', tabla, comparacion });
    },
    [comparacion, pedirExportacion, notify],
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
    // comparación entre grupos (Fase 3B)
    sujetosComparables,
    comparacion,
    comparando,
    comparar,
    exportarComparacion,
  };
}
