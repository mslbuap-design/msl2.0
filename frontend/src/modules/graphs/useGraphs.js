import { useCallback, useEffect, useRef, useState } from 'react';
import * as api from '../../services/api.js';
import { useProjectContext } from '../../context/ProjectContext.jsx';
import { useNativeDialogs } from '../../hooks/useNativeDialogs.js';
import { extractAllCompatibleFiles } from '../../utils/fileTree.js';

/**
 * Estado y lógica propios de Grafos. Mismo patrón que `useRadiomics`/
 * `useStatistics`: lee `structure`/`selectedFile(s)`/`project` del
 * `ProjectContext` y expone su propio estado, sin tocar los otros módulos.
 *
 * FASE 0: el backend (`AnalisisGrafos.jl`) todavía devuelve resultados de
 * prueba (placeholder), no un grafo real — ver docs/CAMBIOS_PARA_GRAFOS.md.
 * El objetivo de esta fase es dejar el flujo completo (este hook -> API ->
 * Jobs -> Excel) andando de punta a punta, para que implementar el
 * algoritmo real (Fase 1-3) no requiera tocar esta capa.
 *
 * `tipoGrafo` está fijo en `'vascular'` por ahora (única rama implementada
 * en el backend; `'conectividad'` responde 501). Cuando se implemente la
 * segunda rama, esto se vuelve una selección real en la UI — el resto del
 * flujo (llamada a la API, manejo de resultados) ya está preparado para
 * recibir cualquiera de los dos valores sin cambios.
 *
 * `opciones` (bbox/umbral de la delimitación hepática ajustable) va vacío
 * por ahora — todavía no existe la interacción de ajuste manual sobre los
 * cortes del visor. Cuando se agregue, alimenta este mismo campo.
 */
export function useGraphs() {
  const { activeTab, structure, selectedFile, selectedFiles, project } = useProjectContext();
  const { notify } = useNativeDialogs();

  const [multipleFilesMode, setMultipleFilesMode] = useState(true);
  const [tipoGrafo] = useState('vascular');
  const [graphsRunning, setGraphsRunning] = useState(false);
  const [graphsResults, setGraphsResults] = useState(null);
  const [expandedResult, setExpandedResult] = useState(null);

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

  const startGraphs = useCallback(async () => {
    if (filesToAnalyze.length === 0) {
      notify('No hay archivos seleccionados');
      return;
    }

    setGraphsRunning(true);
    setGraphsResults(null);

    try {
      const result = await api.analisisGrafos({
        archivos: filesToAnalyze.map((f) => f.fullPath || f.name),
        tipo_grafo: tipoGrafo,
        opciones: {},
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
  }, [filesToAnalyze, tipoGrafo, project, notify]);

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
  };
}
