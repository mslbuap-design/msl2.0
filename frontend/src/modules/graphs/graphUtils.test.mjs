/**
 * Prueba de graphUtils.js (lógica pura del módulo de Grafos): validación y armado de
 * `opciones`, y geometría de las vistas (recorte arrastrable) contra una simulación de
 * `extract_slice` del backend. No necesita dependencias:
 *
 *   node frontend/src/modules/graphs/graphUtils.test.mjs
 *
 * Conviene volver a correrla si se toca graphUtils.js (p. ej. al cambiar los defaults de
 * PARAMS_POR_DEFECTO o el mapeo de ejes de las vistas).
 */
import assert from 'node:assert/strict';
import * as U from './graphUtils.js';
let r = U.construirOpciones(U.PARAMS_POR_DEFECTO, null);
assert.deepEqual(r.opciones, {}); assert.deepEqual(r.errores, []);
r = U.construirOpciones({ ...U.PARAMS_POR_DEFECTO, escalas: '1.5, 3', umbralAuto: false, umbral: '0,02', minVoxeles: '250',
  rellenarCavidades: false, longMinRama: '4', ventana: '3', cAuto: false, c: '0.8', longTortuosidad: '8' }, [1, 100, 5, 90, 2, 30]);
assert.deepEqual(r.opciones, { bbox: [1, 100, 5, 90, 2, 30], escalas_mm: [1.5, 3], c: 0.8, umbral_vesselness: 0.02,
  min_voxeles_componente: 250, rellenar_cavidades: false, longitud_min_rama_mm: 4, ventana_suavizado: 3, longitud_min_tortuosidad_mm: 8 });
r = U.construirOpciones({ ...U.PARAMS_POR_DEFECTO, escalas: '1 2 3', alpha: '0,5', longMinRama: '3.0', longTortuosidad: '5.0' }, null);
assert.deepEqual(r.opciones, {});
r = U.construirOpciones({ ...U.PARAMS_POR_DEFECTO, escalas: '', alpha: '0', beta: 'abc', cAuto: false, c: '',
  umbralAuto: false, umbral: '-1', minVoxeles: '2.5', longMinRama: '-3', factorRadio: 'x', ventana: '20', longTortuosidad: '-1' }, null);
assert.equal(r.errores.length, 10, r.errores.join(' | '));
assert.equal(U.parseEscalas('0.05'), null); assert.equal(U.parseEscalas('25'), null); assert.deepEqual(U.parseEscalas('1,2;3 4'), [1,2,3,4]);
const rotr90 = (A) => { const p = A.length, q = A[0].length; return Array.from({ length: q }, (_, r) => Array.from({ length: p }, (_, c) => A[p - 1 - c][r])); };
const flipRows = (A) => [...A].reverse();
function extractSlice(vol, nx, ny, nz, orient, idx) {
  const f = (get, p, q) => Array.from({ length: p }, (_, i) => Array.from({ length: q }, (_, j) => get(i, j)));
  if (orient === 'sagittal') return flipRows(rotr90(f((j, k) => vol[idx - 1][j][k], ny, nz)));
  if (orient === 'coronal') return rotr90(f((i, k) => vol[i][idx - 1][k], nx, nz));
  return rotr90(f((i, j) => vol[i][j][idx - 1], nx, ny));
}
let semilla = 12345; const azar = (n) => { semilla = (semilla * 1103515245 + 12345) % 2147483648; return semilla % n; };
let casos = 0;
for (let t = 0; t < 200; t += 1) {
  const dims = [5 + azar(9), 5 + azar(9), 5 + azar(9)];
  const lo = dims.map((n) => 1 + azar(n)); const hi = dims.map((n, e) => lo[e] + azar(n - lo[e] + 1));
  const bbox = [lo[0], hi[0], lo[1], hi[1], lo[2], hi[2]];
  const vol = Array.from({ length: dims[0] }, (_, i) => Array.from({ length: dims[1] }, (_, j) => Array.from({ length: dims[2] }, (_, k) =>
    i + 1 >= lo[0] && i + 1 <= hi[0] && j + 1 >= lo[1] && j + 1 <= hi[1] && k + 1 >= lo[2] && k + 1 <= hi[2])));
  for (const orient of ['axial', 'coronal', 'sagittal']) {
    const eje = { axial: 2, coronal: 1, sagittal: 0 }[orient];
    const idx = lo[eje] + azar(hi[eje] - lo[eje] + 1);
    const img = extractSlice(vol, ...dims, orient, idx);
    const filas = img.length, cols = img[0].length;
    let r0 = 1e9, r1 = -1, c0 = 1e9, c1 = -1;
    img.forEach((row, i) => row.forEach((v, j) => { if (v) { r0 = Math.min(r0, i); r1 = Math.max(r1, i); c0 = Math.min(c0, j); c1 = Math.max(c1, j); } }));
    const rect = U.rectanguloDeBbox(orient, dims, bbox);
    const esperado = { left: c0 / cols, top: r0 / filas, width: (c1 - c0 + 1) / cols, height: (r1 - r0 + 1) / filas };
    for (const k of Object.keys(esperado)) assert.ok(Math.abs(rect[k] - esperado[k]) < 1e-9, `${orient} ${k}`);
    const ini = { x: rect.left + 0.01 / cols, y: rect.top + 0.01 / filas };
    const fin = { x: rect.left + rect.width - 0.01 / cols, y: rect.top + rect.height - 0.01 / filas };
    const nuevo = U.bboxDesdeArrastre(orient, dims, U.bboxCompleto(dims), ini, fin);
    const { h, v } = U.VISTAS[orient]; const ih = { x: 0, y: 1, z: 2 }[h], iv = { x: 0, y: 1, z: 2 }[v];
    assert.deepEqual([nuevo[2 * ih], nuevo[2 * ih + 1], nuevo[2 * iv], nuevo[2 * iv + 1]], [bbox[2 * ih], bbox[2 * ih + 1], bbox[2 * iv], bbox[2 * iv + 1]]);
    const ie = { x: 0, y: 1, z: 2 }[U.VISTAS[orient].ejeCorte];
    assert.deepEqual([nuevo[2 * ie], nuevo[2 * ie + 1]], [1, dims[ie]]);
    casos += 1;
  }
}
assert.deepEqual(U.normalizarBbox([50, 10, 0, 999, 3.4, 3.6], [40, 60, 20]), [10, 40, 1, 60, 3, 4]);
assert.equal(U.totalCortes('sagittal', [10, 20, 30]), 10); assert.equal(U.totalCortes('coronal', [10, 20, 30]), 20); assert.equal(U.totalCortes('axial', [10, 20, 30]), 30);
assert.ok(Math.abs(U.aspectoVista('coronal', [100, 100, 50], [1, 1, 3]) - (100 / 150)) < 1e-12);
console.log(`graphUtils: todo OK (${casos} casos de geometría contra simulación de extract_slice)`);
