/**
 * Lógica pura (sin React) del módulo de Grafos: parámetros manuales, armado y
 * validación de `opciones` para el backend, y la geometría de las vistas
 * ortogonales usada por el control de región y el visor de cortes.
 */

// ============================================================================
// PARÁMETROS MANUALES
// ============================================================================

/**
 * Valores por defecto de los controles. DEBEN coincidir con los defaults del
 * backend (PreprocesamientoGrafos.jl / AnalisisGrafos.jl): `construirOpciones`
 * solo envía lo que el usuario cambió, así que el backend sigue siendo la
 * fuente de verdad de los defaults.
 */
export const PARAMS_POR_DEFECTO = {
  escalas: '1, 2, 3',
  alpha: '0.5',
  beta: '0.5',
  cAuto: true,
  c: '',
  umbralAuto: true,
  umbral: '',
  minVoxeles: '100',
  rellenarCavidades: true,
  longMinRama: '3',
  factorRadio: '1.5',
  ventana: '2',
};

const DEFECTOS_NUM = {
  escalas: [1, 2, 3],
  alpha: 0.5,
  beta: 0.5,
  minVoxeles: 100,
  longMinRama: 3,
  factorRadio: 1.5,
  ventana: 2,
};

/** Número desde texto (acepta coma decimal); NaN si está vacío o no es número. */
export function aNumero(texto) {
  const t = String(texto ?? '').trim().replace(',', '.');
  if (t === '') return NaN;
  return Number(t);
}

/**
 * Lista de σ (mm) desde "1, 2.5, 3"; `null` si está vacía o algún valor no es válido (0,1–20 mm).
 * Separadores: coma, punto y coma o espacio — por eso los decimales de ESTE campo van con punto.
 */
export function parseEscalas(texto) {
  const partes = String(texto ?? '')
    .split(/[\s,;]+/)
    .filter((p) => p !== '');
  if (partes.length === 0) return null;
  const valores = partes.map(aNumero);
  if (valores.some((v) => !Number.isFinite(v) || v < 0.1 || v > 20)) return null;
  return valores;
}

function iguales(a, b) {
  return a.length === b.length && a.every((v, i) => v === b[i]);
}

/**
 * Arma el objeto `opciones` del request a partir de los controles. Solo incluye
 * lo que difiere del default (más `bbox`, si hay). Devuelve también los errores
 * de validación (lista de textos); si hay errores no se debe lanzar el análisis.
 *
 * @param {typeof PARAMS_POR_DEFECTO} params
 * @param {number[]|null} bbox  [x0,x1,y0,y1,z0,z1] (1-indexado, inclusivo) o null
 * @returns {{opciones: Object, errores: string[]}}
 */
export function construirOpciones(params, bbox) {
  const errores = [];
  const opciones = {};

  if (bbox) opciones.bbox = bbox;

  const escalas = parseEscalas(params.escalas);
  if (escalas === null) {
    errores.push('Escalas: lista de números entre 0,1 y 20 mm, separados por comas.');
  } else if (!iguales(escalas, DEFECTOS_NUM.escalas)) {
    opciones.escalas_mm = escalas;
  }

  const alpha = aNumero(params.alpha);
  if (!(alpha > 0)) errores.push('Alpha debe ser un número mayor que 0.');
  else if (alpha !== DEFECTOS_NUM.alpha) opciones.alpha = alpha;

  const beta = aNumero(params.beta);
  if (!(beta > 0)) errores.push('Beta debe ser un número mayor que 0.');
  else if (beta !== DEFECTOS_NUM.beta) opciones.beta = beta;

  if (!params.cAuto) {
    const c = aNumero(params.c);
    if (!(c > 0)) errores.push('c (manual) debe ser un número mayor que 0.');
    else opciones.c = c;
  }

  if (!params.umbralAuto) {
    const umbral = aNumero(params.umbral);
    if (!(umbral >= 0)) errores.push('Umbral (manual) debe ser un número mayor o igual que 0.');
    else opciones.umbral_vesselness = umbral;
  }

  const minVox = aNumero(params.minVoxeles);
  if (!Number.isInteger(minVox) || minVox < 1) errores.push('Mín. vóxeles por componente debe ser un entero ≥ 1.');
  else if (minVox !== DEFECTOS_NUM.minVoxeles) opciones.min_voxeles_componente = minVox;

  if (!params.rellenarCavidades) opciones.rellenar_cavidades = false;

  const longMin = aNumero(params.longMinRama);
  if (!(longMin >= 0)) errores.push('Longitud mínima de rama debe ser un número ≥ 0 (mm).');
  else if (longMin !== DEFECTOS_NUM.longMinRama) opciones.longitud_min_rama_mm = longMin;

  const factor = aNumero(params.factorRadio);
  if (!(factor >= 0)) errores.push('Factor de radio debe ser un número ≥ 0.');
  else if (factor !== DEFECTOS_NUM.factorRadio) opciones.factor_radio_poda = factor;

  const ventana = aNumero(params.ventana);
  if (!Number.isInteger(ventana) || ventana < 0 || ventana > 10) errores.push('Ventana de suavizado debe ser un entero entre 0 y 10.');
  else if (ventana !== DEFECTOS_NUM.ventana) opciones.ventana_suavizado = ventana;

  return { opciones, errores };
}

// ============================================================================
// GEOMETRÍA DE LAS VISTAS
// ============================================================================
//
// El backend dibuja cada corte con `extract_slice` (rotaciones incluidas), así
// que en pantalla los ejes del volumen aparecen así (verificado numéricamente
// contra la implementación Julia):
//   axial:    horizontal = x (invertido), vertical = y,             corta en z
//   coronal:  horizontal = x (invertido), vertical = z,             corta en y
//   sagital:  horizontal = y (invertido), vertical = z (invertido), corta en x
// `dims` = [nx, ny, nz]; los índices de vóxel son 1-indexados.

export const VISTAS = {
  axial: { nombre: 'Axial', h: 'x', v: 'y', hRev: true, vRev: false, ejeCorte: 'z' },
  coronal: { nombre: 'Coronal', h: 'x', v: 'z', hRev: true, vRev: false, ejeCorte: 'y' },
  sagittal: { nombre: 'Sagital', h: 'y', v: 'z', hRev: true, vRev: true, ejeCorte: 'x' },
};

const IDX_EJE = { x: 0, y: 1, z: 2 };

export function dimDeEje(dims, eje) {
  return dims[IDX_EJE[eje]];
}

/** Cantidad de cortes de una orientación. */
export function totalCortes(orientacion, dims) {
  return dimDeEje(dims, VISTAS[orientacion].ejeCorte);
}

/** Relación ancho/alto de una vista, respetando el tamaño físico del vóxel (mm). */
export function aspectoVista(orientacion, dims, voxel) {
  const { h, v } = VISTAS[orientacion];
  const sh = voxel?.[IDX_EJE[h]] > 0 ? voxel[IDX_EJE[h]] : 1;
  const sv = voxel?.[IDX_EJE[v]] > 0 ? voxel[IDX_EJE[v]] : 1;
  return (dimDeEje(dims, h) * sh) / (dimDeEje(dims, v) * sv);
}

export function bboxCompleto(dims) {
  return [1, dims[0], 1, dims[1], 1, dims[2]];
}

export function bboxEsCompleto(bbox, dims) {
  const c = bboxCompleto(dims);
  return bbox.every((v, i) => v === c[i]);
}

/** Fuerza 1 ≤ mín ≤ máx ≤ n en cada eje. */
export function normalizarBbox(bbox, dims) {
  const salida = [];
  for (let e = 0; e < 3; e += 1) {
    const n = dims[e];
    let a = Math.round(Number(bbox[2 * e]));
    let b = Math.round(Number(bbox[2 * e + 1]));
    if (!Number.isFinite(a)) a = 1;
    if (!Number.isFinite(b)) b = n;
    a = Math.min(n, Math.max(1, a));
    b = Math.min(n, Math.max(1, b));
    salida.push(Math.min(a, b), Math.max(a, b));
  }
  return salida;
}

export function describirBbox(bbox) {
  return `x ${bbox[0]}–${bbox[1]} · y ${bbox[2]}–${bbox[3]} · z ${bbox[4]}–${bbox[5]}`;
}

function rangoPix(a0, a1, n, rev) {
  return rev ? [n - a1 + 1, n - a0 + 1] : [a0, a1];
}

/**
 * Rectángulo (fracciones 0–1 del ancho/alto de la imagen) que ocupa el bbox en una vista.
 * @returns {{left: number, top: number, width: number, height: number}}
 */
export function rectanguloDeBbox(orientacion, dims, bbox) {
  const { h, v, hRev, vRev } = VISTAS[orientacion];
  const nh = dimDeEje(dims, h);
  const nv = dimDeEje(dims, v);
  const [h0, h1] = rangoPix(bbox[2 * IDX_EJE[h]], bbox[2 * IDX_EJE[h] + 1], nh, hRev);
  const [v0, v1] = rangoPix(bbox[2 * IDX_EJE[v]], bbox[2 * IDX_EJE[v] + 1], nv, vRev);
  return { left: (h0 - 1) / nh, top: (v0 - 1) / nv, width: (h1 - h0 + 1) / nh, height: (v1 - v0 + 1) / nv };
}

function ejeDesdeFraccion(f, n, rev) {
  const p = Math.min(n, Math.max(1, Math.floor(f * n) + 1));
  return rev ? n - p + 1 : p;
}

/**
 * Nuevo bbox al arrastrar un rectángulo sobre una vista: reemplaza los dos ejes
 * visibles en esa vista y conserva el tercero.
 * @param {{x: number, y: number}} ini  punto inicial, fracciones 0–1 de la imagen
 * @param {{x: number, y: number}} fin  punto final, fracciones 0–1 de la imagen
 */
export function bboxDesdeArrastre(orientacion, dims, bbox, ini, fin) {
  const { h, v, hRev, vRev } = VISTAS[orientacion];
  const nh = dimDeEje(dims, h);
  const nv = dimDeEje(dims, v);
  const h0 = ejeDesdeFraccion(ini.x, nh, hRev);
  const h1 = ejeDesdeFraccion(fin.x, nh, hRev);
  const v0 = ejeDesdeFraccion(ini.y, nv, vRev);
  const v1 = ejeDesdeFraccion(fin.y, nv, vRev);
  const nuevo = [...bbox];
  nuevo[2 * IDX_EJE[h]] = Math.min(h0, h1);
  nuevo[2 * IDX_EJE[h] + 1] = Math.max(h0, h1);
  nuevo[2 * IDX_EJE[v]] = Math.min(v0, v1);
  nuevo[2 * IDX_EJE[v] + 1] = Math.max(v0, v1);
  return nuevo;
}
