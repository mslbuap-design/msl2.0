import { CheckCircle2, ChevronDown, ChevronRight, FlaskConical, XCircle } from 'lucide-react';
import Button from '../../components/ui/Button.jsx';
import EmptyState from '../../components/ui/EmptyState.jsx';
import { extractAllCompatibleFiles } from '../../utils/fileTree.js';
import { formatFeatureValue } from '../../utils/format.js';
import { useRadiomics } from './useRadiomics.js';

export default function RadiomicsTab() {
  const {
    multipleFilesMode,
    setMultipleFilesMode,
    parallelMode,
    setParallelMode,
    radiomicsRunning,
    radiomicsResults,
    expandedResult,
    setExpandedResult,
    startRadiomics,
    structure,
    selectedFiles,
  } = useRadiomics();

  const allCompatibleCount = structure ? extractAllCompatibleFiles(structure, 'radiomics').length : 0;

  return (
    <div className="h-full min-h-0 flex gap-4">
      {/* PANEL IZQUIERDO */}
      <div className="w-80 flex-shrink-0">
        <h2 className="text-xl font-semibold text-ink mb-4 flex items-center gap-2">
          <FlaskConical size={20} className="text-accent" />
          Análisis radiómico
        </h2>

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

          <label className="flex items-center gap-3 cursor-pointer">
            <input
              type="checkbox"
              checked={parallelMode}
              onChange={(e) => setParallelMode(e.target.checked)}
              className="w-4 h-4 accent-accent"
            />
            <span className="text-sm font-medium text-ink">Procesamiento en paralelo</span>
          </label>
        </div>

        <Button onClick={startRadiomics} disabled={radiomicsRunning} fullWidth>
          {radiomicsRunning ? 'Analizando...' : 'Iniciar análisis radiómico'}
        </Button>

        {multipleFilesMode && structure && !radiomicsRunning && (
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
        {radiomicsResults ? (
          <>
            <h3 className="text-base font-semibold text-ink mb-3">Resultados</h3>
            <div className="flex-1 min-h-0 overflow-auto bg-surface rounded-lg border border-line">
              <table className="min-w-full divide-y divide-line">
                <thead className="bg-bg sticky top-0">
                  <tr>
                    {['Archivo', 'Características', 'Estado', 'Acción'].map((h) => (
                      <th key={h} className="px-6 py-3 text-left text-xs font-medium text-muted">
                        {h}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody className="divide-y divide-line">
                  {radiomicsResults.map((result, idx) => (
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
            icon={FlaskConical}
            title="Selecciona archivos e inicia el análisis"
          />
        )}
      </div>
    </div>
  );
}

function ResultRow({ result, isExpanded, onToggle }) {
  return (
    <>
      <tr className="hover:bg-bg">
        <td className="px-6 py-4 text-sm font-medium text-ink">{result.archivo}</td>
        <td className="px-6 py-4 text-sm text-muted font-data">{result.num_caracteristicas || '-'} features</td>
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
          {result.success && (
            <button onClick={onToggle} className="inline-flex items-center gap-1 text-accent hover:text-accent-700 font-medium">
              {isExpanded ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
              {isExpanded ? 'Ocultar' : 'Ver detalles'}
            </button>
          )}
        </td>
      </tr>
      {isExpanded && result.success && (
        <tr>
          <td colSpan={4} className="px-6 py-4 bg-bg">
            <div className="space-y-3">
              {result.caracteristicas &&
                Object.entries(result.caracteristicas).map(([categoria, features]) => (
                  <div key={categoria} className="border-l-2 border-accent pl-4">
                    <h4 className="font-semibold text-ink mb-2 text-sm capitalize">
                      {categoria.replace(/_/g, ' ')}
                    </h4>
                    <div className="grid grid-cols-2 md:grid-cols-3 gap-2 text-sm">
                      {Object.entries(features).map(([key, value]) => (
                        <div key={key} className="bg-surface p-2 rounded border border-line">
                          <span className="text-muted">{key}:</span>{' '}
                          <span className="font-medium text-ink font-data">{formatFeatureValue(value)}</span>
                        </div>
                      ))}
                    </div>
                  </div>
                ))}
            </div>
          </td>
        </tr>
      )}
    </>
  );
}
