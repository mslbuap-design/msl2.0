import { useCallback, useEffect, useRef, useState } from 'react';
import * as api from '../../services/api.js';
import { useProjectContext } from '../../context/ProjectContext.jsx';
import { useNativeDialogs } from '../../hooks/useNativeDialogs.js';
import { extractAllCompatibleFiles } from '../../utils/fileTree.js';

/**
 * Estado y lógica propios de Radiómica.
 *
 * Nota de fidelidad: cuando "Analizar múltiples archivos" está desmarcado,
 * el análisis usa `selectedFile` (el archivo actualmente abierto en
 * Visualización) en vez de la selección múltiple — así se comportaba el
 * App.js original (ambos compartían el mismo estado global) y se conserva
 * aquí vía el contexto.
 */
export function useRadiomics() {
  const { activeTab, structure, selectedFile, selectedFiles, project } = useProjectContext();
  const { notify } = useNativeDialogs();

  const [multipleFilesMode, setMultipleFilesMode] = useState(true);
  const [parallelMode, setParallelMode] = useState(false);
  const [radiomicsRunning, setRadiomicsRunning] = useState(false);
  const [radiomicsResults, setRadiomicsResults] = useState(null);
  const [expandedResult, setExpandedResult] = useState(null);

  // Al activarse la pestaña, forzar modo múltiple (igual que handleTabChange original).
  const wasActive = useRef(false);
  useEffect(() => {
    const isActive = activeTab === 'radiomics';
    if (isActive && !wasActive.current) setMultipleFilesMode(true);
    wasActive.current = isActive;
  }, [activeTab]);

  const filesToAnalyze = multipleFilesMode
    ? selectedFiles.length > 0
      ? selectedFiles
      : extractAllCompatibleFiles(structure || {}, 'radiomics')
    : selectedFile
      ? [selectedFile]
      : [];

  const startRadiomics = useCallback(async () => {
    if (filesToAnalyze.length === 0) {
      notify('No hay archivos seleccionados');
      return;
    }

    setRadiomicsRunning(true);
    setRadiomicsResults(null);

    try {
      // `f.fullPath` (ruta absoluta dentro del proyecto) en vez de `f.name`:
      // el backend la usa directo, sin necesitar que el archivo se haya
      // re-subido antes a TEMP_DIR. `ruta_proyecto` es necesaria para que
      // el Excel de resultados se guarde en la carpeta del proyecto
      // correcto (antes dependía de un estado global compartido).
      const result = await api.analisisRadiomico({
        archivos: filesToAnalyze.map((f) => f.fullPath || f.name),
        modo_paralelo: parallelMode,
        ruta_proyecto: project?.ruta || '',
      });

      if (result.success) {
        setRadiomicsResults(result.resultados);
        notify(`✅ Análisis completado\n${filesToAnalyze.length} archivo(s) procesado(s)`);
      } else {
        notify(`❌ Error: ${result.error}`);
      }
    } catch (error) {
      console.error('Error:', error);
      notify('Error de conexión');
    } finally {
      setRadiomicsRunning(false);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [filesToAnalyze, parallelMode, project, notify]);

  return {
    multipleFilesMode,
    setMultipleFilesMode,
    parallelMode,
    setParallelMode,
    radiomicsRunning,
    radiomicsResults,
    expandedResult,
    setExpandedResult,
    filesToAnalyze,
    startRadiomics,
    structure,
    selectedFiles,
  };
}
