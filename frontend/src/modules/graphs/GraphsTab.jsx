import { AlertTriangle, CheckCircle2, ChevronDown, ChevronRight, Network, XCircle } from 'lucide-react';
import Button from '../../components/ui/Button.jsx';
import EmptyState from '../../components/ui/EmptyState.jsx';
import { extractAllCompatibleFiles } from '../../utils/fileTree.js';
import { useGraphs } from './useGraphs.js';

export default function GraphsTab() {
  const {
    multipleFilesMode,
    setMultipleFilesMode,
    graphsRunning,
    graphsResults,
    expandedResult,
    setExpandedResult,
    startGraphs,
    structure,
    selectedFiles,
  } = useGraphs();

  const allCompatibleCount = structure ? extractAllCompatibleFiles(structure, 'graphs').length : 0;

  return (
    <div className="h-full min-h-0 flex gap-4">
      {/* PANEL IZQUIERDO */}
      <div className="w-80 flex-shrink-0">
        <h2 className="text-xl font-semibold text-ink mb-4 flex items-center gap-2">
          <Network size={20} className="text-accent" />
          Análisis por grafos
        </h2>

        <div className="mb-4 p-3 bg-amber-50 rounded-lg border border-amber-200 flex gap-2">
          <AlertTriangle size={16} className="text-amber-600 flex-shrink-0 mt-0.5" />
          <p className="text-xs text-amber-800">
            Fase 1: ya corre el realce vascular (Frangi) + binarización
            reales. La esqueletización y el grafo (nodos/aristas/métricas)
            todavía no están implementados — ver docs/CAMBIOS_PARA_GRAFOS.md.
          </p>
        </div>

        <div className="bg-bg rounded-lg p-4 mb-4 border border-line space-y-3">
          <label className="flex items-center gap-3 cursor-pointer">
            <input
              type="checkbox"
              checked={multipleFilesMode}
              onChange={(e) => setMultipleFilesMode(e.target.checked)}
              className="w-4 h-4 accent-accent"
            />
            <span className="text-sm font-medium text-ink">Analizar múltiples archivos</span>
          </label>

          <div className="text-xs text-muted">
            Tipo de grafo: <span className="font-medium text-ink">vascular</span> (estático)
          </div>
        </div>

        <Button onClick={startGraphs} disabled={graphsRunning} fullWidth>
          {graphsRunning ? 'Analizando...' : 'Iniciar análisis por grafos'}
        </Button>

        {multipleFilesMode && structure && !graphsRunning && (
          <div className="mt-4 p-3 bg-accent-50 rounded-lg border border-accent/20">
            <p className="text-sm text-accent-700">
              {selectedFiles.length > 0
                ? `${selectedFiles.length} archivo(s) seleccionado(s)`
                : `Se analizarán todos los archivos compatibles (${allCompatibleCount})`}
            </p>
          </div>
        )}
      </div>

      {/* PANEL DERECHO */}
      <div className="flex-1 min-h-0 flex flex-col min-w-0">
        {graphsResults ? (
          <>
            <h3 className="text-base font-semibold text-ink mb-3">Resultados</h3>
            <div className="flex-1 min-h-0 overflow-auto bg-surface rounded-lg border border-line">
              <table className="min-w-full divide-y divide-line">
                <thead className="bg-bg sticky top-0">
                  <tr>
                    {['Archivo', 'Vóxeles vasculares', '% del volumen', 'Estado', 'Acción'].map((h) => (
                      <th key={h} className="px-6 py-3 text-left text-xs font-medium text-muted">
                        {h}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody className="divide-y divide-line">
                  {graphsResults.map((result, idx) => (
                    <ResultRow
                      key={idx}
                      result={result}
                      isExpanded={expandedResult === idx}
                      onToggle={() => setExpandedResult(expandedResult === idx ? null : idx)}
                    />
                  ))}
                </tbody>
              </table>
            </div>
          </>
        ) : (
          <EmptyState
            icon={Network}
            title="Selecciona archivos e inicia el análisis"
          />
        )}
      </div>
    </div>
  );
}

function ResultRow({ result, isExpanded, onToggle }) {
  const d = result.deteccion_vascular || {};
  const viz = result.visualizacion || {};
  const porcentaje = d.fraccion_volumen != null ? `${(d.fraccion_volumen * 100).toFixed(2)}%` : '-';

  return (
    <>
      <tr className="hover:bg-bg">
        <td className="px-6 py-4 text-sm font-medium text-ink">{result.archivo}</td>
        <td className="px-6 py-4 text-sm text-muted font-data">{d.voxeles_vasculares ?? '-'}</td>
        <td className="px-6 py-4 text-sm text-muted font-data">{porcentaje}</td>
        <td className="px-6 py-4">
          <span
            className={`inline-flex items-center gap-1.5 px-2 py-0.5 text-xs font-medium rounded-full ${
              result.success ? 'bg-success-50 text-success' : 'bg-danger-50 text-danger'
            }`}
          >
            {result.success ? <CheckCircle2 size={12} /> : <XCircle size={12} />}
            {result.success ? 'Completado' : 'Error'}
          </span>
        </td>
        <td className="px-6 py-4 text-sm">
          {result.success ? (
            <button onClick={onToggle} className="inline-flex items-center gap-1 text-accent hover:text-accent-700 font-medium">
              {isExpanded ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
              {isExpanded ? 'Ocultar' : 'Ver detalles'}
            </button>
          ) : (
            <span className="text-danger text-xs">{result.error}</span>
          )}
        </td>
      </tr>
      {isExpanded && result.success && (
        <tr>
          <td colSpan={5} className="px-6 py-4 bg-bg">
            <div className="space-y-4">
              {result.fase_pipeline && (
                <div className="p-2.5 bg-amber-50 border border-amber-200 rounded text-xs text-amber-800 flex gap-2">
                  <AlertTriangle size={14} className="flex-shrink-0 mt-0.5" />
                  <span>{result.fase_pipeline}</span>
                </div>
              )}

              <div className="grid grid-cols-2 md:grid-cols-3 gap-2 text-sm">
                <Metric label="Vóxeles vasculares" value={d.voxeles_vasculares} />
                <Metric label="Fracción del volumen" value={porcentaje} />
                <Metric label="Umbral vesselness" value={d.umbral_vesselness?.toFixed?.(4) ?? d.umbral_vesselness} />
                <Metric label="Origen del umbral" value={d.origen_umbral} />
                <Metric label="Escalas (mm)" value={(d.escalas_mm || []).join(', ')} />
                <Metric label="Región analizada" value={result.region?.origen} />
              </div>

              {(viz.corte_original_png || viz.corte_mascara_png) && (
                <div>
                  <p className="text-xs text-muted mb-2">
                    Validación visual — corte axial {viz.indice_corte_axial} (original vs. máscara vascular detectada):
                  </p>
                  <div className="flex gap-3">
                    {viz.corte_original_png && (
                      <figure className="flex-1">
                        <img src={viz.corte_original_png} alt="Corte original" className="w-full rounded border border-line bg-black" />
                        <figcaption className="text-xs text-faint text-center mt-1">Original</figcaption>
                      </figure>
                    )}
                    {viz.corte_mascara_png && (
                      <figure className="flex-1">
                        <img src={viz.corte_mascara_png} alt="Máscara vascular detectada" className="w-full rounded border border-line bg-black" />
                        <figcaption className="text-xs text-faint text-center mt-1">Máscara detectada</figcaption>
                      </figure>
                    )}
                  </div>
                </div>
              )}
            </div>
          </td>
        </tr>
      )}
    </>
  );
}

function Metric({ label, value }) {
  return (
    <div className="bg-surface p-2 rounded border border-line">
      <span className="text-muted">{label}:</span>{' '}
      <span className="font-medium text-ink font-data">{value ?? '-'}</span>
    </div>
  );
}
