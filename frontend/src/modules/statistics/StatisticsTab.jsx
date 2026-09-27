import { AlertTriangle, BarChart3, Folder } from 'lucide-react';
import Button from '../../components/ui/Button.jsx';
import EmptyState from '../../components/ui/EmptyState.jsx';
import { useStatistics } from './useStatistics.js';

const TEST_OPTIONS = [
  { key: 'tTest', label: 'Prueba T de Student' },
  { key: 'anova', label: 'ANOVA / ANCOVA' },
  { key: 'correlation', label: 'Test de Correlación' },
  { key: 'multipleComparisons', label: 'Comparaciones Múltiples (Tukey/Bonferroni)' },
  { key: 'nonParametric', label: 'Pruebas No Paramétricas (Mann-Whitney/Kruskal-Wallis)' },
  { key: 'fisherVariance', label: 'Prueba F de Fisher (Varianzas)' },
  { key: 'correlationMatrix', label: 'Matriz de Correlación (R y p-valor)' },
  { key: 'zVariance', label: 'Prueba Z de Varianzas' },
];

const NOMBRES_PRUEBAS = {
  normalityTest: 'Test de Normalidad',
  tTest: 'Prueba T de Student',
  anova: 'ANOVA',
  correlation: 'Correlación',
  multipleComparisons: 'Comparaciones Múltiples',
  nonParametric: 'Pruebas No Paramétricas',
  fisherVariance: 'Prueba F de Fisher',
  correlationMatrix: 'Matriz de Correlación',
  zVariance: 'Prueba Z de Varianzas',
};

/** Aplana el resultado de una prueba en una o más filas de tabla. */
function rowsForTest(prueba, resultado) {
  const nombrePrueba = NOMBRES_PRUEBAS[prueba] || prueba;

  if (typeof resultado !== 'object' || resultado?.error) {
    return [{ key: prueba, nombrePrueba, estadistico: '-', pValor: '-', conclusion: '-' }];
  }

  if (prueba === 'normalityTest') {
    return Object.entries(resultado).map(([grupo, test], subIdx) => ({
      key: `${prueba}-${grupo}`,
      nombrePrueba: `${subIdx === 0 ? nombrePrueba : ''} ${grupo ? `(${grupo})` : ''}`.trim(),
      estadistico: test.W ? `W = ${test.W}` : '-',
      pValor: test.p_value || '-',
      conclusion: test.conclusion || '-',
    }));
  }

  let estadistico = '-';
  if (resultado.t_statistic) estadistico = `t = ${resultado.t_statistic}`;
  else if (resultado.F_statistic) estadistico = `F = ${resultado.F_statistic}`;
  else if (resultado.U_statistic) estadistico = `U = ${resultado.U_statistic}`;
  else if (resultado.H_statistic) estadistico = `H = ${resultado.H_statistic}`;
  else if (resultado.Z_statistic) estadistico = `Z = ${resultado.Z_statistic}`;
  else if (resultado.r) estadistico = `r = ${resultado.r}`;
  else if (resultado.rho) estadistico = `ρ = ${resultado.rho}`;

  return [{
    key: prueba,
    nombrePrueba,
    estadistico,
    pValor: resultado.p_value || '-',
    conclusion: resultado.conclusion || resultado.test_aplicado || '-',
  }];
}

export default function StatisticsTab() {
  const {
    statisticsRunning,
    statisticsResults,
    compareByFiles,
    setCompareByFiles,
    selectedTests,
    toggleTest,
    selectedFiles,
    selectedFolders,
    startStatistics,
  } = useStatistics();

  const hasExcel = selectedFiles.some((f) => /\.(xlsx|xls)$/i.test(f.name));

  return (
    <div className="h-full min-h-0 flex gap-4">
      {/* PANEL IZQUIERDO */}
      <div className="w-80 flex-shrink-0">
        <h2 className="text-xl font-semibold text-ink mb-4 flex items-center gap-2">
          <BarChart3 size={20} className="text-accent" />
          Análisis estadístico
        </h2>

        <div className="bg-bg rounded-lg p-4 mb-4 border border-line">
          <h3 className="font-semibold text-ink text-sm mb-3">Pruebas a realizar</h3>
          <div className="space-y-2 max-h-64 overflow-y-auto">
            {TEST_OPTIONS.map(({ key, label }) => (
              <label key={key} className="flex items-center gap-2 cursor-pointer">
                <input
                  type="checkbox"
                  checked={selectedTests[key]}
                  onChange={() => toggleTest(key)}
                  className="w-4 h-4 accent-accent"
                />
                <span className="text-sm text-ink">{label}</span>
              </label>
            ))}
          </div>
        </div>

        {hasExcel && (
          <div className="bg-warning-50 rounded-lg p-4 mb-4 border border-warning/20">
            <h3 className="font-semibold text-warning mb-2 text-sm">Archivos Excel detectados</h3>
            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                checked={compareByFiles}
                onChange={(e) => setCompareByFiles(e.target.checked)}
                className="w-4 h-4 accent-warning"
              />
              <span className="text-sm text-warning">
                Comparar entre archivos (desmarcar para comparar entre carpetas)
              </span>
            </label>
          </div>
        )}

        <Button onClick={startStatistics} disabled={statisticsRunning} fullWidth>
          {statisticsRunning ? 'Analizando...' : 'Iniciar análisis estadístico'}
        </Button>

        <div className="mt-4 p-3 bg-accent-50 rounded-lg border border-accent/20">
          <p className="text-sm font-medium text-accent-700 mb-2">
            Grupos seleccionados: {selectedFolders.length}
          </p>
          {selectedFolders.length > 0 && (
            <ul className="text-xs text-accent-700 space-y-1 max-h-32 overflow-y-auto">
              {selectedFolders.map((folder, idx) => (
                <li key={idx} className="flex items-center gap-1.5">
                  <Folder size={11} />
                  {folder.name}
                </li>
              ))}
            </ul>
          )}
          {selectedFolders.length < 2 && (
            <p className="text-xs text-danger mt-2 flex items-center gap-1.5">
              <AlertTriangle size={12} />
              Necesitas seleccionar al menos 2 grupos
            </p>
          )}
        </div>
      </div>

      {/* PANEL DERECHO */}
      <div className="flex-1 min-h-0 flex flex-col min-w-0">
        {statisticsResults ? (
          <>
            <h3 className="text-base font-semibold text-ink mb-3">Resultados estadísticos</h3>
            <div className="flex-1 min-h-0 overflow-auto bg-surface rounded-lg border border-line">
              <table className="min-w-full divide-y divide-line">
                <thead className="bg-bg sticky top-0">
                  <tr>
                    {['Prueba', 'Estadístico', 'P-valor', 'Conclusión'].map((h) => (
                      <th key={h} className="px-6 py-3 text-left text-xs font-medium text-muted">
                        {h}
                      </th>
                    ))}
                  </tr>
                </thead>
                <tbody className="divide-y divide-line">
                  {Object.entries(statisticsResults).flatMap(([prueba, resultado]) =>
                    rowsForTest(prueba, resultado).map((row) => (
                      <tr key={row.key} className="hover:bg-bg">
                        <td className="px-6 py-4 text-sm font-medium text-ink">{row.nombrePrueba}</td>
                        <td className="px-6 py-4 text-sm text-muted font-data">{row.estadistico}</td>
                        <td className="px-6 py-4 text-sm text-muted font-data">{row.pValor}</td>
                        <td className="px-6 py-4 text-sm text-muted">{row.conclusion}</td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </div>
          </>
        ) : (
          <EmptyState
            icon={BarChart3}
            title="Selecciona grupos y pruebas estadísticas"
            description="Marca al menos 2 carpetas en el árbol de archivos y selecciona las pruebas que deseas realizar"
          />
        )}
      </div>
    </div>
  );
}
