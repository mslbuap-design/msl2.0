import { Crop, RotateCcw } from 'lucide-react';
import { describirBbox } from './graphUtils.js';

const CLASE_INPUT =
  'w-full px-2 py-1 text-sm border border-line rounded bg-surface text-ink font-data focus:outline-none focus:ring-1 focus:ring-accent disabled:bg-bg disabled:text-faint';

function Seccion({ titulo, abierta = false, children }) {
  return (
    <details open={abierta} className="bg-bg rounded-lg border border-line">
      <summary className="px-3 py-2 text-sm font-medium text-ink cursor-pointer select-none">{titulo}</summary>
      <div className="px-3 pb-3 pt-1 space-y-2.5">{children}</div>
    </details>
  );
}

function Campo({ etiqueta, ayuda, children }) {
  return (
    <div title={ayuda}>
      <span className="block text-xs text-muted mb-1">{etiqueta}</span>
      {children}
    </div>
  );
}

function Texto({ etiqueta, valor, onCambio, deshabilitado = false }) {
  return (
    <input
      type="text"
      inputMode="decimal"
      aria-label={etiqueta}
      value={valor}
      disabled={deshabilitado}
      onChange={(e) => onCambio(e.target.value)}
      className={CLASE_INPUT}
    />
  );
}

function Casilla({ marcada, onCambio, etiqueta }) {
  return (
    <label className="flex items-center gap-2 text-xs text-muted cursor-pointer">
      <input type="checkbox" checked={marcada} onChange={(e) => onCambio(e.target.checked)} className="w-3.5 h-3.5 accent-accent" />
      {etiqueta}
    </label>
  );
}

/**
 * Controles manuales del análisis por grafos: región (Paso 0) y parámetros del
 * preprocesamiento y del grafo. Los valores por defecto viven en
 * `graphUtils.js` (`PARAMS_POR_DEFECTO`) y coinciden con los del backend.
 */
export default function ControlesGrafos({
  params,
  setParam,
  restablecerParams,
  errores,
  bbox,
  setBbox,
  abrirRegion,
  hayArchivos,
}) {
  return (
    <div className="space-y-2 mb-4">
      <Seccion titulo="Región de análisis" abierta>
        <p className="text-sm text-ink font-data">{bbox ? describirBbox(bbox) : 'Volumen completo'}</p>
        <div className="flex gap-2">
          <button
            onClick={abrirRegion}
            disabled={!hayArchivos}
            className="flex-1 inline-flex items-center justify-center gap-1.5 px-2 py-1.5 text-xs font-medium rounded border border-line bg-surface text-ink hover:bg-accent-50 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            <Crop size={13} />
            Definir región…
          </button>
          {bbox && (
            <button
              onClick={() => setBbox(null)}
              className="px-2 py-1.5 text-xs font-medium rounded border border-line bg-surface text-muted hover:bg-bg"
            >
              Quitar
            </button>
          )}
        </div>
      </Seccion>

      <Seccion titulo="Realce vascular (Frangi)">
        <Campo etiqueta="Escalas σ (mm)" ayuda="Calibres de vaso a detectar, en mm, separados por coma. Decimales con punto.">
          <Texto etiqueta="Escalas σ (mm)" valor={params.escalas} onCambio={(v) => setParam('escalas', v)} />
        </Campo>
        <div className="grid grid-cols-2 gap-2">
          <Campo etiqueta="Alpha" ayuda="Estrictez tubo vs. placa (default 0.5)">
            <Texto etiqueta="Alpha" valor={params.alpha} onCambio={(v) => setParam('alpha', v)} />
          </Campo>
          <Campo etiqueta="Beta" ayuda="Estrictez tubo vs. bola (default 0.5)">
            <Texto etiqueta="Beta" valor={params.beta} onCambio={(v) => setParam('beta', v)} />
          </Campo>
        </div>
        <Campo etiqueta="c" ayuda="Sensibilidad al ruido de fondo. Automático: se adapta a la intensidad de cada imagen.">
          <Casilla marcada={params.cAuto} onCambio={(v) => setParam('cAuto', v)} etiqueta="Automático" />
          <Texto etiqueta="c" valor={params.c} onCambio={(v) => setParam('c', v)} deshabilitado={params.cAuto} />
        </Campo>
        <Campo etiqueta="Umbral de vesselness" ayuda="Valor a partir del cual un vóxel cuenta como vaso. Automático: Otsu.">
          <Casilla marcada={params.umbralAuto} onCambio={(v) => setParam('umbralAuto', v)} etiqueta="Automático (Otsu)" />
          <Texto etiqueta="Umbral de vesselness" valor={params.umbral} onCambio={(v) => setParam('umbral', v)} deshabilitado={params.umbralAuto} />
        </Campo>
      </Seccion>

      <Seccion titulo="Limpieza de la máscara">
        <Campo etiqueta="Mín. vóxeles por componente" ayuda="Las componentes conexas con menos vóxeles se descartan (default 100).">
          <Texto etiqueta="Mín. vóxeles por componente" valor={params.minVoxeles} onCambio={(v) => setParam('minVoxeles', v)} />
        </Campo>
        <Casilla
          marcada={params.rellenarCavidades}
          onCambio={(v) => setParam('rellenarCavidades', v)}
          etiqueta="Rellenar cavidades internas"
        />
      </Seccion>

      <Seccion titulo="Grafo">
        <Campo etiqueta="Longitud mín. de rama (mm)" ayuda="Poda: las ramas terminales más cortas que esto se eliminan (default 3).">
          <Texto etiqueta="Longitud mín. de rama (mm)" valor={params.longMinRama} onCambio={(v) => setParam('longMinRama', v)} />
        </Campo>
        <Campo etiqueta="Factor de radio (poda)" ayuda="Poda: ...o más cortas que este múltiplo del radio de la rama más gruesa de su bifurcación (default 1.5).">
          <Texto etiqueta="Factor de radio (poda)" valor={params.factorRadio} onCambio={(v) => setParam('factorRadio', v)} />
        </Campo>
        <Campo etiqueta="Ventana de suavizado" ayuda="Semiventana (en vóxeles de camino) del suavizado de la línea central antes de medir longitudes (default 2).">
          <Texto etiqueta="Ventana de suavizado" valor={params.ventana} onCambio={(v) => setParam('ventana', v)} />
        </Campo>
      </Seccion>

      {errores.length > 0 && (
        <ul className="text-xs text-danger space-y-0.5 px-1">
          {errores.map((e) => (
            <li key={e}>• {e}</li>
          ))}
        </ul>
      )}

      <button
        onClick={restablecerParams}
        className="w-full inline-flex items-center justify-center gap-1.5 px-2 py-1.5 text-xs font-medium rounded border border-line bg-surface text-muted hover:bg-bg"
      >
        <RotateCcw size={12} />
        Restablecer parámetros
      </button>
    </div>
  );
}
