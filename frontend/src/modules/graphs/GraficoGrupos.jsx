import { useMemo } from 'react';
import { enjambre, fmtNum, mediana, rangoEjeY, ticksBonitos } from './comparacionUtils.js';

/** Un color por grupo (de la paleta de la app); la posición en el eje X y la etiqueta también identifican el grupo. */
const COLORES = ['#5B6B7A', '#0F6E8C', '#9A6A16', '#1B7A43', '#6B4C9A', '#B3261E'];
const MARGEN = { izq: 58, der: 12, arriba: 12, abajo: 36 };
const ANCHO_COLUMNA = 120;
const ALTO_AREA = 176;
const RADIO = 3.5;

/**
 * Valores de UNA característica, un punto por sujeto, agrupados. Con n chico, ver los puntos dice más que una caja.
 * `puntos` = `{grupo: [{valor, archivo}]}`; `grupos` fija el orden (el primero es la referencia).
 * La línea oscura de cada columna es la mediana del grupo.
 */
export default function GraficoGrupos({ puntos, grupos, dec = 2, etiqueta = '' }) {
  const g = useMemo(() => {
    const todos = grupos.flatMap((nombre) => (puntos[nombre] || []).map((p) => p.valor));
    const { min, max } = rangoEjeY(todos);
    const yPx = (v) => MARGEN.arriba + ((max - v) / (max - min)) * ALTO_AREA;
    const limite = ANCHO_COLUMNA / 2 - RADIO - 4;
    const columnas = grupos.map((nombre, i) => {
      const pts = puntos[nombre] || [];
      const ys = pts.map((p) => yPx(p.valor));
      const dx = enjambre(ys, RADIO);
      const centro = MARGEN.izq + ANCHO_COLUMNA * i + ANCHO_COLUMNA / 2;
      return {
        nombre,
        centro,
        color: COLORES[i % COLORES.length],
        n: pts.length,
        med: mediana(pts.map((p) => p.valor)),
        puntos: pts.map((p, k) => ({ ...p, x: centro + Math.max(-limite, Math.min(limite, dx[k])), y: ys[k] })),
      };
    });
    return { min, max, yPx, ticks: ticksBonitos(min, max, 4), columnas };
  }, [puntos, grupos]);

  const ancho = MARGEN.izq + ANCHO_COLUMNA * grupos.length + MARGEN.der;
  const alto = MARGEN.arriba + ALTO_AREA + MARGEN.abajo;
  const resumen = g.columnas.map((c) => `${c.nombre}: ${c.n} sujetos, mediana ${fmtNum(c.med, dec)}`).join('; ');

  return (
    <svg
      viewBox={`0 0 ${ancho} ${alto}`}
      width="100%"
      style={{ maxWidth: ancho * 1.6 }}
      role="img"
      aria-label={`Valores de ${etiqueta || 'la característica'} por sujeto en cada grupo. ${resumen}`}
      className="bg-surface rounded border border-line"
    >
      {g.ticks.map((t) => (
        <g key={t}>
          <line x1={MARGEN.izq} x2={ancho - MARGEN.der} y1={g.yPx(t)} y2={g.yPx(t)} className="stroke-line" strokeWidth="1" />
          <text x={MARGEN.izq - 6} y={g.yPx(t) + 3} textAnchor="end" fontSize="10" className="fill-muted font-data">
            {fmtNum(t, dec)}
          </text>
        </g>
      ))}

      {g.columnas.map((c) => (
        <g key={c.nombre}>
          {c.puntos.map((p, k) => (
            <circle key={k} cx={p.x} cy={p.y} r={RADIO} fill={c.color} fillOpacity="0.8" stroke="#FFFFFF" strokeWidth="0.75">
              <title>{`${p.archivo}: ${fmtNum(p.valor, dec + 1)}`}</title>
            </circle>
          ))}
          {c.med !== null && (
            <line x1={c.centro - 30} x2={c.centro + 30} y1={g.yPx(c.med)} y2={g.yPx(c.med)} stroke="#14213D" strokeWidth="2.25" strokeLinecap="round">
              <title>{`Mediana de ${c.nombre}: ${fmtNum(c.med, dec + 1)}`}</title>
            </line>
          )}
          <text x={c.centro} y={MARGEN.arriba + ALTO_AREA + 16} textAnchor="middle" fontSize="11" className="fill-ink">
            {c.nombre.length > 16 ? `${c.nombre.slice(0, 15)}…` : c.nombre}
          </text>
          <text x={c.centro} y={MARGEN.arriba + ALTO_AREA + 29} textAnchor="middle" fontSize="10" className="fill-muted font-data">
            n = {c.n}
          </text>
        </g>
      ))}
    </svg>
  );
}
