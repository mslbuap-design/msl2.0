import { CheckCircle2, ChevronDown, ChevronRight, Network, XCircle } from 'lucide-react';
import Button from '../../components/ui/Button.jsx';
import EmptyState from '../../components/ui/EmptyState.jsx';
import { extractAllCompatibleFiles } from '../../utils/fileTree.js';
import ControlesGrafos from './ControlesGrafos.jsx';
import RegionModal from './RegionModal.jsx';
import VisorCortes from './VisorCortes.jsx';
import { useGraphs } from './useGraphs.js';

/** Marca de fase (sin explicaciones: el detalle vive en docs/CAMBIOS_PARA_GRAFOS.md). */
function MarcaFase({ texto = 'Fase 2' }) {
  return (
    <span className="inline-block px-2 py-0.5 text-xs font-medium rounded bg-amber-50 border border-amber-200 text-amber-800">
      {texto}
    </span>
  );
}

/** Número con `d` decimales, o '-' si no hay valor (null/undefined/NaN). */
function fmt(value, d = 2) {
  return typeof value === 'number' && Number.isFinite(value) ? value.toFixed(d) : '-';
}

export default function GraphsTab() {
  const {
    multipleFilesMode,
    setMultipleFilesMode,
    graphsRunning,
    graphsResults,
    expandedResult,
    setExpandedResult,
    startGraphs,
    filesToAnalyze,
    structure,
    selectedFiles,
    params,
    setParam,
    restablecerParams,
    erroresParams,
    bbox,
    setBbox,
    regionAbierta,
    setRegionAbierta,
  } = useGraphs();

  const allCompatibleCount = structure ? extractAllCompatibleFiles(structure, 'graphs').length : 0;

  return (
    <div className="h-full min-h-0 flex gap-4">
      {/* PANEL IZQUIERDO */}
      <div className="w-80 flex-shrink-0 overflow-y-auto pr-1">
        <div className="flex items-center justify-between mb-4">
          <h2 className="text-xl font-semibold text-ink flex items-center gap-2">
            <Network size={20} className="text-accent" />
            Análisis por grafos
          </h2>
          <MarcaFase />
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

        <h3 className="text-sm font-semibold text-ink mt-5 mb-2">Controles manuales</h3>
        <ControlesGrafos
          params={params}
          setParam={setParam}
          restablecerParams={restablecerParams}
          errores={erroresParams}
          bbox={bbox}
          setBbox={setBbox}
          abrirRegion={() => setRegionAbierta(true)}
          hayArchivos={filesToAnalyze.length > 0}
        />
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
                    {['Archivo', 'Bifurcaciones', 'Puntas', 'Longitud (mm)', 'Estado', 'Acción'].map((h) => (
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
          <EmptyState icon={Network} title="Selecciona archivos e inicia el análisis" />
        )}
      </div>

      {regionAbierta && filesToAnalyze.length > 0 && (
        <RegionModal
          archivos={filesToAnalyze}
          bboxInicial={bbox}
          onAplicar={(nuevo) => {
            setBbox(nuevo);
            setRegionAbierta(false);
          }}
          onCerrar={() => setRegionAbierta(false)}
        />
      )}
    </div>
  );
}

function ResultRow({ result, isExpanded, onToggle }) {
  const d = result.deteccion_vascular || {};
  const g = result.grafo?.metricas || {};
  const viz = result.visualizacion || {};

  return (
    <>
      <tr className="hover:bg-bg">
        <td className="px-6 py-4 text-sm font-medium text-ink">{result.archivo}</td>
        <td className="px-6 py-4 text-sm text-muted font-data">{g.num_bifurcaciones ?? '-'}</td>
        <td className="px-6 py-4 text-sm text-muted font-data">{g.num_puntas ?? '-'}</td>
        <td className="px-6 py-4 text-sm text-muted font-data">{fmt(g.longitud_vascular_total_mm, 1)}</td>
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
          <td colSpan={6} className="px-6 py-4 bg-bg">
            <div className="space-y-4">
              {result.fase_pipeline && <MarcaFase texto={result.fase_pipeline} />}

              <div>
                <p className="text-xs font-medium text-muted mb-2">Grafo</p>
                <div className="grid grid-cols-2 md:grid-cols-3 gap-2 text-sm">
                  <Metric label="Nodos" value={g.num_nodos} />
                  <Metric label="Aristas" value={g.num_aristas} />
                  <Metric label="Longitud total" value={`${fmt(g.longitud_vascular_total_mm, 1)} mm`} />
                  <Metric label="Radio promedio" value={`${fmt(g.radio_promedio_mm, 2)} mm`} />
                  <Metric label="Tortuosidad promedio" value={fmt(g.tortuosidad_promedio, 3)} />
                  <Metric label="Componentes" value={g.num_componentes} />
                  <Metric label="Ciclos independientes" value={g.ciclos_independientes} />
                  <Metric label="Vóxeles del esqueleto" value={result.esqueleto?.voxeles} />
                </div>
                {result.grafo?.ruta_json && (
                  <p className="text-xs text-faint mt-2 break-all">Grafo completo (nodos y aristas): {result.grafo.ruta_json}</p>
                )}
              </div>

              <div>
                <p className="text-xs font-medium text-muted mb-2">Preprocesamiento</p>
                <div className="grid grid-cols-2 md:grid-cols-3 gap-2 text-sm">
                  <Metric label="Vóxeles vasculares" value={d.voxeles_vasculares} />
                  <Metric label="Fracción del volumen" value={d.fraccion_volumen != null ? `${(d.fraccion_volumen * 100).toFixed(2)}%` : '-'} />
                  <Metric label="Umbral vesselness" value={`${fmt(d.umbral_vesselness, 4)} (${d.origen_umbral ?? '-'})`} />
                  <Metric label="Escalas (mm)" value={(d.escalas_mm || []).join(', ')} />
                  <Metric label="Componentes (antes → después)" value={`${d.componentes_antes ?? '-'} → ${d.componentes_despues ?? '-'}`} />
                  <Metric label="Cavidades rellenadas" value={`${d.voxeles_cavidades_rellenadas ?? '-'} vóxeles`} />
                </div>
                <p className="text-xs text-faint mt-2">
                  Región analizada: {result.region?.origen ?? '-'}
                  {result.region?.bbox_usado ? ` [${Array.from(result.region.bbox_usado).join(', ')}]` : ''}
                </p>
              </div>

              <div>
                <p className="text-xs font-medium text-muted mb-2">Validación visual</p>
                {result.resultado_id && result.dimensiones ? (
                  <VisorCortes
                    resultadoId={result.resultado_id}
                    dimensiones={result.dimensiones}
                    voxelDims={result.voxel_dims_mm}
                  />
                ) : (
                  <p className="text-xs text-faint">Cortes no disponibles para este resultado.</p>
                )}
              </div>

              {viz.proyeccion_esqueleto_png && (
                <figure className="max-w-md">
                  <img
                    src={viz.proyeccion_esqueleto_png}
                    alt="Proyección axial del esqueleto"
                    className="w-full rounded border border-line bg-black"
                  />
                  <figcaption className="text-xs text-faint mt-1">
                    Proyección axial: máscara en gris, esqueleto en rojo, bifurcaciones en amarillo, puntas en cian
                  </figcaption>
                </figure>
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
