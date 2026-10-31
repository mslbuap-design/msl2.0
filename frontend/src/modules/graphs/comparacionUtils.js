/**
 * Lógica pura de la comparación entre grupos (pestaña Grafos, Fase 3B): arma lo que se envía a
 * /api/grafos/comparar, valida la selección, avisa de diferencias de resolución y da formato a los
 * resultados. Sin React ni dependencias, para poder probarla con Node:
 *
 *   node frontend/src/modules/graphs/comparacionUtils.test.mjs
 *
 * Orientación (igual que en el backend, ComparacionGrupos.jl): el primer grupo de la selección es la
 * REFERENCIA y todo efecto se lee "grupo comparado frente a la referencia"; con más de dos grupos, cada
 * par (a, b), con a antes que b, se lee "b frente a a". Definiciones: docs/CAMBIOS_PARA_GRAFOS.md.
 */
import { GRUPOS_METRICAS } from './metricasCatalogo.js';
import { aNumero } from './graphUtils.js';

export const SIN_GRUPO = '(sin grupo)';
/** Cociente entre medianas de resolución del vóxel (de un grupo a otro) a partir del cual se avisa. */
export const RAZON_RESOLUCION = 1.15;
export const ALFA_POR_DEFECTO = '0.05';

const esNumero = (x) => typeof x === 'number' && Number.isFinite(x);

// ----------------------------------------------------------------------------
// Sujetos y grupos
// ----------------------------------------------------------------------------

/**
 * Una entrada por resultado exitoso con sus características: `{archivo, grupo, caracteristicas, voxel_dims_mm}`.
 * La unidad de análisis es el sujeto (una fila por archivo).
 */
export function sujetosDeResultados(resultados) {
  const salida = [];
  for (const r of resultados || []) {
    const c = r?.avanzadas?.caracteristicas;
    if (!r?.success || !c || typeof c !== 'object') continue;
    salida.push({ archivo: r.archivo, grupo: r.grupo || SIN_GRUPO, caracteristicas: c, voxel_dims_mm: r.voxel_dims_mm ?? null });
  }
  return salida;
}

/** Grupos presentes, en orden de aparición, con su n; `comparable` = n ≥ 2. */
export function gruposDisponibles(sujetos) {
  const orden = [];
  const cuenta = new Map();
  for (const s of sujetos) {
    if (!cuenta.has(s.grupo)) {
      cuenta.set(s.grupo, 0);
      orden.push(s.grupo);
    }
    cuenta.set(s.grupo, cuenta.get(s.grupo) + 1);
  }
  return orden.map((nombre) => ({ nombre, n: cuenta.get(nombre), comparable: cuenta.get(nombre) >= 2 }));
}

/** Pares (grupo, archivo) que aparecen más de una vez entre los grupos elegidos (el backend los rechaza). */
export function sujetosRepetidos(sujetos, grupos) {
  const vistos = new Set();
  const repetidos = [];
  for (const s of sujetos) {
    if (!grupos.includes(s.grupo)) continue;
    const clave = `${s.grupo}\u0000${s.archivo}`;
    if (vistos.has(clave)) repetidos.push(`${s.archivo} (${s.grupo})`);
    vistos.add(clave);
  }
  return repetidos;
}

/** Mensajes de lo que impide comparar con esa selección (vacío = se puede). */
export function validarSeleccion(seleccion, disponibles, sujetos = []) {
  const errores = [];
  if (seleccion.length < 2) errores.push('Elige al menos 2 grupos para comparar.');
  for (const g of seleccion) {
    const d = disponibles.find((x) => x.nombre === g);
    const n = d ? d.n : 0;
    if (n < 2) errores.push(`«${g}» tiene ${n} sujeto(s): hacen falta al menos 2.`);
  }
  const rep = sujetosRepetidos(sujetos, seleccion);
  if (rep.length > 0) errores.push(`Hay archivos repetidos dentro de un mismo grupo: ${rep.join(', ')}. Se compara un valor por sujeto.`);
  return errores;
}

/** Selección con la referencia primero; el resto conserva su orden. Si la referencia no está elegida, queda igual. */
export function ordenarConReferencia(seleccion, referencia) {
  if (!seleccion.includes(referencia)) return [...seleccion];
  return [referencia, ...seleccion.filter((g) => g !== referencia)];
}

/**
 * Cuerpo de POST /api/grafos/comparar. Solo viajan archivo, grupo y características de los grupos elegidos
 * (no las resoluciones ni nada más). `errores` no vacío = no enviar.
 */
export function construirPeticion({ sujetos, grupos, pruebaPrincipal, alfaTexto }) {
  const errores = [];
  const alfa = aNumero(alfaTexto);
  if (!(alfa > 0 && alfa < 1)) errores.push('α debe ser un número entre 0 y 1 (p. ej. 0,05).');
  if (!['no_parametrica', 'parametrica'].includes(pruebaPrincipal)) errores.push('Elige la prueba principal.');
  const peticion = {
    sujetos: sujetos
      .filter((s) => grupos.includes(s.grupo))
      .map((s) => ({ archivo: s.archivo, grupo: s.grupo, caracteristicas: s.caracteristicas })),
    grupos,
    prueba_principal: pruebaPrincipal,
    alfa,
  };
  return { peticion, errores };
}

// ----------------------------------------------------------------------------
// Estadística descriptiva mínima (para el gráfico y el aviso)
// ----------------------------------------------------------------------------

/** Percentil `p` (0..1) con interpolación lineal (igual que numpy.percentile y el backend). */
export function percentil(valores, p) {
  const s = valores.filter(esNumero).sort((a, b) => a - b);
  if (s.length === 0) return null;
  const pos = p * (s.length - 1);
  const lo = Math.floor(pos);
  const hi = Math.min(lo + 1, s.length - 1);
  return s[lo] + (pos - lo) * (s[hi] - s[lo]);
}

export const mediana = (valores) => percentil(valores, 0.5);

/**
 * ¿Difieren las resoluciones del vóxel entre los grupos comparados? Compara la mediana por grupo de cada eje:
 * si el mayor cociente entre grupos supera `razon`, la diferencia entre grupos podría venir de la resolución
 * y no de la anatomía. Devuelve `{hay, detalle: [{eje, razon}], porGrupo: {grupo: [x, y, z]}}`.
 */
export function avisoResolucion(sujetos, grupos, razon = RAZON_RESOLUCION) {
  const porGrupo = {};
  for (const g of grupos) {
    const dims = sujetos
      .filter((s) => s.grupo === g && Array.isArray(s.voxel_dims_mm) && s.voxel_dims_mm.length >= 3)
      .map((s) => s.voxel_dims_mm);
    if (dims.length > 0) porGrupo[g] = [0, 1, 2].map((k) => mediana(dims.map((d) => d[k])));
  }
  const nombres = Object.keys(porGrupo);
  const detalle = [];
  if (nombres.length >= 2) {
    ['x', 'y', 'z'].forEach((eje, k) => {
      const vals = nombres.map((g) => porGrupo[g][k]).filter((v) => esNumero(v) && v > 0);
      if (vals.length < 2) return;
      const cociente = Math.max(...vals) / Math.min(...vals);
      if (cociente > razon) detalle.push({ eje, razon: cociente });
    });
  }
  return { hay: detalle.length > 0, detalle, porGrupo };
}

// ----------------------------------------------------------------------------
// Formato de resultados
// ----------------------------------------------------------------------------

/** Etiqueta, grupo, decimales y ayuda de una característica según el catálogo; lo desconocido se muestra por su clave. */
export function infoCaracteristica(clave) {
  for (const g of GRUPOS_METRICAS) {
    const item = g.items.find((i) => i.clave === clave);
    if (item) return { clave, grupo: g.titulo, etiqueta: item.etiqueta, dec: item.dec ?? 2, ayuda: item.ayuda || '' };
  }
  return { clave, grupo: '', etiqueta: clave, dec: 3, ayuda: '' };
}

/** Número con `dec` decimales, o '—' si no hay valor. */
export function fmtNum(valor, dec = 2) {
  return esNumero(valor) ? valor.toFixed(dec) : '—';
}

/** p-valor: 3 decimales, y '<0.001' si es menor; '—' si no hay. */
export function formatearP(p) {
  if (!esNumero(p)) return '—';
  return p < 0.001 ? '<0.001' : p.toFixed(3);
}

/** `mediana (p25–p75)` de los descriptivos de un grupo, o '—'. */
export function formatearMediana(desc, dec = 2) {
  if (!desc || !esNumero(desc.mediana)) return '—';
  return `${fmtNum(desc.mediana, dec)} (${fmtNum(desc.p25, dec)}–${fmtNum(desc.p75, dec)})`;
}

/** `valor [inf; sup]` o solo `valor` si el intervalo no es estimable. */
export function formatearConIC(valor, ic, dec = 2) {
  if (!esNumero(valor)) return '—';
  if (!Array.isArray(ic) || !esNumero(ic[0]) || !esNumero(ic[1])) return fmtNum(valor, dec);
  return `${fmtNum(valor, dec)} [${fmtNum(ic[0], dec)}; ${fmtNum(ic[1], dec)}]`;
}

/** Una línea con la prueba: `Mann–Whitney U = 36.00, exacto, p = 0.035`; sin prueba, el motivo habitual. */
export function formatearPrueba(prueba) {
  if (!prueba) return 'No estimable (varianza cero en algún grupo)';
  const glNum = (x) => fmtNum(x, Number.isInteger(x) ? 0 : 2);
  let gl = null;
  if (Array.isArray(prueba.gl)) gl = `gl ${prueba.gl.map(glNum).join('; ')}`;
  else if (esNumero(prueba.gl)) gl = `gl ${glNum(prueba.gl)}`;
  return [`${prueba.nombre} = ${fmtNum(prueba.estadistico, 2)}`, gl, prueba.metodo || null, `p = ${formatearP(prueba.p)}`].filter(Boolean).join(', ');
}

/** Magnitud orientativa de δ de Cliff (Romano et al.: 0,147 / 0,33 / 0,474). */
export function magnitudCliff(delta) {
  if (!esNumero(delta)) return null;
  const a = Math.abs(delta);
  if (a < 0.147) return 'despreciable';
  if (a < 0.33) return 'pequeño';
  if (a < 0.474) return 'mediano';
  return 'grande';
}

/** Cómo se lee el signo de los efectos para esta comparación. */
export function textoOrientacion(grupos) {
  if (!Array.isArray(grupos) || grupos.length < 2) return '';
  if (grupos.length === 2) {
    return `δ de Cliff y g de Hedges positivos (AUC > 0,5): «${grupos[1]}» tiende a valores mayores que «${grupos[0]}» (referencia).`;
  }
  return `Cada par se lee «segundo grupo» frente a «primero» (referencia: «${grupos[0]}»).`;
}

/** Filas que se muestran: todas, o solo las significativas. */
export function filasVisibles(resultados, soloSignificativas) {
  const filas = resultados || [];
  return soloSignificativas ? filas.filter((f) => f.significativa === true) : filas;
}

/** Texto corto del estado de una fila que no tiene p (para la tabla). */
export function textoEstado(fila) {
  switch (fila.estado) {
    case 'sin_variacion':
      return 'Sin variación';
    case 'omitida':
      return 'Omitida';
    case 'no_estimable':
      return 'No estimable';
    default:
      return '';
  }
}

// ----------------------------------------------------------------------------
// Geometría del gráfico de puntos por grupo
// ----------------------------------------------------------------------------

/** Valores finitos de una característica por grupo, en el orden de `grupos`. */
export function valoresPorGrupo(sujetos, clave, grupos) {
  const salida = {};
  for (const g of grupos) {
    salida[g] = sujetos.filter((s) => s.grupo === g).map((s) => s.caracteristicas?.[clave]).filter(esNumero);
  }
  return salida;
}

/** Como `valoresPorGrupo`, pero cada punto lleva su archivo (`{valor, archivo}`), para el tooltip del gráfico. */
export function puntosPorGrupo(sujetos, clave, grupos) {
  const salida = {};
  for (const g of grupos) {
    salida[g] = sujetos
      .filter((s) => s.grupo === g && esNumero(s.caracteristicas?.[clave]))
      .map((s) => ({ valor: s.caracteristicas[clave], archivo: s.archivo }));
  }
  return salida;
}

/** Marcas "bonitas" (1, 2, 5 × 10ⁿ) entre `min` y `max`, unas `n` en total. */
export function ticksBonitos(min, max, n = 4) {
  if (!esNumero(min) || !esNumero(max) || max < min) return [];
  if (max === min) return [min];
  const bruto = (max - min) / Math.max(n, 1);
  const pot = 10 ** Math.floor(Math.log10(bruto));
  const f = bruto / pot;
  const paso = (f < 1.5 ? 1 : f < 3.5 ? 2 : f < 7.5 ? 5 : 10) * pot;
  const ticks = [];
  for (let v = Math.ceil(min / paso - 1e-9) * paso; v <= max + paso * 1e-9; v += paso) {
    ticks.push(Math.abs(v) < paso * 1e-9 ? 0 : Number(v.toPrecision(12)));
  }
  return ticks;
}

/** Rango del eje Y con 8 % de margen; si todo vale lo mismo, un rango simbólico alrededor. */
export function rangoEjeY(valores) {
  const v = valores.filter(esNumero);
  if (v.length === 0) return { min: 0, max: 1 };
  let min = Math.min(...v);
  let max = Math.max(...v);
  if (min === max) {
    const d = Math.abs(min) * 0.05 || 1;
    return { min: min - d, max: max + d };
  }
  const margen = (max - min) * 0.08;
  min -= margen;
  max += margen;
  return { min, max };
}

/**
 * Desplazamiento horizontal (en px) de cada punto para que no se tapen (enjambre determinista): los puntos
 * se colocan en orden y cada uno toma el desplazamiento libre más cercano al centro (0, +d, −d, +2d, …).
 * `ys` = posición vertical (px) de cada punto, `radio` = radio de cada punto. Misma entrada, misma salida.
 */
export function enjambre(ys, radio) {
  const orden = ys.map((y, i) => i).sort((a, b) => ys[a] - ys[b] || a - b);
  const colocados = [];
  const dx = new Array(ys.length).fill(0);
  const paso = radio * 0.9;
  for (const i of orden) {
    let elegido = 0;
    for (let k = 0; k < 400; k += 1) {
      const candidato = k === 0 ? 0 : (k % 2 === 1 ? 1 : -1) * Math.ceil(k / 2) * paso;
      const choca = colocados.some((c) => (c.x - candidato) ** 2 + (c.y - ys[i]) ** 2 < (2 * radio) ** 2 - 1e-9);
      if (!choca) {
        elegido = candidato;
        break;
      }
    }
    dx[i] = elegido;
    colocados.push({ x: elegido, y: ys[i] });
  }
  return dx;
}
