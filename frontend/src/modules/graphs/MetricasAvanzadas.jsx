import { GRUPOS_METRICAS, formatearMetrica } from './metricasCatalogo.js';

/** Histograma simple (barras SVG) de una distribución por arista. `datos` = {bordes, conteos}. */
function Histograma({ titulo, datos, dec = 2 }) {
  if (!datos || !datos.conteos?.length) return null;
  const { bordes, conteos } = datos;
  const ancho = 200;
  const alto = 56;
  const maximo = Math.max(...conteos, 1);
  const anchoBarra = ancho / conteos.length;
  return (
    <figure className="min-w-0">
      <figcaption className="text-xs text-muted mb-1">{titulo}</figcaption>
      <svg
        viewBox={`0 0 ${ancho} ${alto}`}
        preserveAspectRatio="none"
        className="w-full h-16 bg-surface rounded border border-line"
        role="img"
        aria-label={`Histograma de ${titulo}`}
      >
        {conteos.map((c, i) => {
          const h = (c / maximo) * (alto - 4);
          return (
            <rect key={i} x={i * anchoBarra + 0.5} y={alto - h} width={Math.max(anchoBarra - 1, 0.5)} height={h} className="fill-accent" />
          );
        })}
      </svg>
      <div className="flex justify-between text-[10px] text-faint font-data">
        <span>{formatearMetrica(bordes[0], dec)}</span>
        <span>{formatearMetrica(bordes[bordes.length - 1], dec)}</span>
      </div>
    </figure>
  );
}

/** Valores por orden de Strahler (corrientes, longitud media y radio medio). */
function TablaPorOrden({ jerarquia }) {
  const ordenes = Object.keys(jerarquia?.n_por_orden || {})
    .map(Number)
    .sort((a, b) => a - b);
  if (ordenes.length === 0) return null;
  return (
    <div>
      <p className="text-xs font-medium text-muted mb-1">Por orden de Strahler</p>
      <table className="text-xs border border-line rounded bg-surface">
        <thead className="bg-bg text-muted">
          <tr>
            <th className="px-3 py-1 text-left font-medium">Orden</th>
            <th className="px-3 py-1 text-right font-medium">Corrientes</th>
            <th className="px-3 py-1 text-right font-medium">Longitud media (mm)</th>
            <th className="px-3 py-1 text-right font-medium">Radio medio (mm)</th>
          </tr>
        </thead>
        <tbody className="font-data">
          {ordenes.map((k) => (
            <tr key={k} className="border-t border-line">
              <td className="px-3 py-1">{k}</td>
              <td className="px-3 py-1 text-right">{jerarquia.n_por_orden[k]}</td>
              <td className="px-3 py-1 text-right">{formatearMetrica(jerarquia.longitud_media_por_orden?.[k], 1)}</td>
              <td className="px-3 py-1 text-right">{formatearMetrica(jerarquia.radio_medio_por_orden?.[k], 2)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

/**
 * Métricas avanzadas de un grafo (Fase 3A): distribuciones por arista, jerarquía,
 * geometría de las bifurcaciones y caminos. Las definiciones exactas están en el
 * tooltip de cada valor y en docs/CAMBIOS_PARA_GRAFOS.md.
 *
 * @param {{avanzadas: {caracteristicas: Object, estructura: Object, histogramas: Object}}} props
 */
export default function MetricasAvanzadas({ avanzadas }) {
  if (!avanzadas?.caracteristicas) return null;
  const car = avanzadas.caracteristicas;
  const hist = avanzadas.histogramas || {};

  return (
    <div className="space-y-3">
      <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
        <Histograma titulo="Radio por arista (mm)" datos={hist.radio_mm} dec={2} />
        <Histograma titulo="Longitud por arista (mm)" datos={hist.longitud_mm} dec={1} />
        <Histograma titulo="Tortuosidad por arista" datos={hist.tortuosidad} dec={2} />
      </div>

      {GRUPOS_METRICAS.map((grupo) => (
        <details key={grupo.titulo} className="bg-surface rounded border border-line">
          <summary className="px-3 py-2 text-sm font-medium text-ink cursor-pointer select-none" title={grupo.descripcion}>
            {grupo.titulo}
          </summary>
          <div className="px-3 pb-3 pt-1">
            <p className="text-xs text-faint mb-2">{grupo.descripcion}</p>
            <div className="grid grid-cols-2 md:grid-cols-3 gap-2 text-sm">
              {grupo.items.map((it) => (
                <div key={it.clave} className="bg-bg p-2 rounded border border-line" title={it.ayuda || it.etiqueta}>
                  <span className="text-muted">{it.etiqueta}:</span>{' '}
                  <span className="font-medium text-ink font-data">{formatearMetrica(car[it.clave], it.dec)}</span>
                </div>
              ))}
            </div>
          </div>
        </details>
      ))}

      <TablaPorOrden jerarquia={avanzadas.estructura?.jerarquia} />
    </div>
  );
}
