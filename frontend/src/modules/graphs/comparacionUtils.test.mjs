/**
 * Prueba de comparacionUtils.js (lógica pura de la comparación entre grupos, Fase 3B): armado y validación
 * de la petición, aviso de resolución, formato de resultados y geometría del gráfico. Sin dependencias:
 *
 *   node frontend/src/modules/graphs/comparacionUtils.test.mjs
 *
 * Conviene volver a correrla si se toca comparacionUtils.js (p. ej. el umbral RAZON_RESOLUCION o las
 * magnitudes de δ de Cliff). Los percentiles se contrastaron con numpy.percentile.
 */
import assert from 'node:assert/strict';
import * as C from './comparacionUtils.js';
import { GRUPOS_METRICAS } from './metricasCatalogo.js';

const ok = (nombre) => console.log('  ok  ' + nombre);

// --- sujetos y grupos --------------------------------------------------------------------------
const resultados = [
  { archivo: 'a.nii', grupo: 'Sanos', success: true, voxel_dims_mm: [1, 1, 3], avanzadas: { caracteristicas: { radio_media_mm: 1.5, n_arboles: 2 } } },
  { archivo: 'b.nii', grupo: 'Sanos', success: true, voxel_dims_mm: [1, 1, 3], avanzadas: { caracteristicas: { radio_media_mm: 1.7, n_arboles: 1 } } },
  { archivo: 'c.nii', grupo: 'Enfermos', success: true, voxel_dims_mm: [1.5, 1.5, 3], avanzadas: { caracteristicas: { radio_media_mm: 2.4, n_arboles: 3 } } },
  { archivo: 'd.nii', grupo: 'Enfermos', success: true, voxel_dims_mm: [1.5, 1.5, 3], avanzadas: { caracteristicas: { radio_media_mm: 2.1, n_arboles: 3 } } },
  { archivo: 'e.nii', grupo: 'Enfermos', success: true, voxel_dims_mm: [1.5, 1.5, 3], avanzadas: { caracteristicas: { radio_media_mm: null, n_arboles: 4 } } },
  { archivo: 'f.nii', grupo: 'Solo', success: true, avanzadas: { caracteristicas: { radio_media_mm: 9 } } },
  { archivo: 'g.nii', grupo: 'Sanos', success: false, error: 'falló' },
  { archivo: 'h.nii', grupo: 'Sanos', success: true },
  { archivo: 'i.nii', success: true, avanzadas: { caracteristicas: { radio_media_mm: 1 } } },
];
const sujetos = C.sujetosDeResultados(resultados);
assert.deepEqual(sujetos.map((s) => s.archivo), ['a.nii', 'b.nii', 'c.nii', 'd.nii', 'e.nii', 'f.nii', 'i.nii']);
assert.equal(sujetos[6].grupo, C.SIN_GRUPO);
assert.equal(sujetos[5].voxel_dims_mm, null);
ok('sujetosDeResultados: descarta fallidos y sin características; sin grupo → (sin grupo)');

const disp = C.gruposDisponibles(sujetos);
assert.deepEqual(disp, [
  { nombre: 'Sanos', n: 2, comparable: true },
  { nombre: 'Enfermos', n: 3, comparable: true },
  { nombre: 'Solo', n: 1, comparable: false },
  { nombre: C.SIN_GRUPO, n: 1, comparable: false },
]);
ok('gruposDisponibles: orden de aparición, n y comparable (n ≥ 2)');

assert.deepEqual(C.validarSeleccion(['Sanos', 'Enfermos'], disp, sujetos), []);
assert.equal(C.validarSeleccion(['Sanos'], disp, sujetos).length, 1);
assert.deepEqual(C.validarSeleccion(['Sanos', 'Solo'], disp, sujetos), ['«Solo» tiene 1 sujeto(s): hacen falta al menos 2.']);
const conRepetido = [...sujetos, { archivo: 'a.nii', grupo: 'Sanos', caracteristicas: {} }];
assert.match(C.validarSeleccion(['Sanos', 'Enfermos'], disp, conRepetido)[0], /repetidos.*a\.nii \(Sanos\)/);
assert.deepEqual(C.sujetosRepetidos([{ archivo: 'p.nii', grupo: 'A' }, { archivo: 'p.nii', grupo: 'B' }], ['A', 'B']), []);
ok('validarSeleccion: ≥ 2 grupos, n ≥ 2 por grupo y archivos repetidos; mismo nombre en grupos distintos es válido');

assert.deepEqual(C.ordenarConReferencia(['A', 'B', 'C'], 'B'), ['B', 'A', 'C']);
assert.deepEqual(C.ordenarConReferencia(['A', 'B'], 'Z'), ['A', 'B']);
ok('ordenarConReferencia: la referencia pasa al frente');

// --- petición ----------------------------------------------------------------------------------
let r = C.construirPeticion({ sujetos, grupos: ['Sanos', 'Enfermos'], pruebaPrincipal: 'no_parametrica', alfaTexto: '0,05' });
assert.deepEqual(r.errores, []);
assert.equal(r.peticion.alfa, 0.05);
assert.deepEqual(r.peticion.grupos, ['Sanos', 'Enfermos']);
assert.equal(r.peticion.sujetos.length, 5);
assert.deepEqual(Object.keys(r.peticion.sujetos[0]).sort(), ['archivo', 'caracteristicas', 'grupo']);
assert.equal(r.peticion.sujetos[4].caracteristicas.radio_media_mm, null);
ok('construirPeticion: solo los grupos elegidos, solo archivo/grupo/características, α con coma decimal, null se conserva');
assert.equal(C.construirPeticion({ sujetos, grupos: ['Sanos'], pruebaPrincipal: 'parametrica', alfaTexto: '1.5' }).errores.length, 1);
assert.equal(C.construirPeticion({ sujetos, grupos: ['Sanos'], pruebaPrincipal: 'parametrica', alfaTexto: '' }).errores.length, 1);
assert.equal(C.construirPeticion({ sujetos, grupos: ['Sanos'], pruebaPrincipal: 'otra', alfaTexto: '0.05' }).errores.length, 1);
ok('construirPeticion: α fuera de (0, 1), vacío o prueba inválida → error');

// --- resolución del vóxel ----------------------------------------------------------------------
let av = C.avisoResolucion(sujetos, ['Sanos', 'Enfermos']);
assert.equal(av.hay, true);
assert.deepEqual(av.detalle.map((d) => d.eje), ['x', 'y']);
assert.ok(Math.abs(av.detalle[0].razon - 1.5) < 1e-12);
assert.deepEqual(av.porGrupo.Sanos, [1, 1, 3]);
av = C.avisoResolucion(sujetos.filter((s) => s.grupo === 'Sanos'), ['Sanos', 'Enfermos']);
assert.equal(av.hay, false);
const justo = [{ grupo: 'A', voxel_dims_mm: [1, 1, 1] }, { grupo: 'A', voxel_dims_mm: [1, 1, 1] }, { grupo: 'B', voxel_dims_mm: [1.15, 1, 1] }, { grupo: 'B', voxel_dims_mm: [1.15, 1, 1] }];
assert.equal(C.avisoResolucion(justo, ['A', 'B']).hay, false);
assert.equal(C.avisoResolucion(justo, ['A', 'B'], 1.1).hay, true);
const medianas = [{ grupo: 'A', voxel_dims_mm: [1, 1, 1] }, { grupo: 'A', voxel_dims_mm: [1, 1, 1] }, { grupo: 'A', voxel_dims_mm: [5, 5, 5] },
  { grupo: 'B', voxel_dims_mm: [1, 1, 1] }, { grupo: 'B', voxel_dims_mm: [1, 1, 1] }];
assert.equal(C.avisoResolucion(medianas, ['A', 'B']).hay, false);
ok('avisoResolucion: cociente de medianas por grupo y eje (estricto > 1,15); un valor atípico no la dispara');

// --- percentiles y formato ---------------------------------------------------------------------
const v = [3, 1, 4, 1, 5, 9, 2, 6];
assert.equal(C.percentil(v, 0.25), 1.75);
assert.equal(C.percentil(v, 0.5), 3.5);
assert.equal(C.percentil(v, 0.75), 5.25);
assert.equal(C.mediana([7]), 7);
assert.equal(C.mediana([]), null);
ok('percentil: interpolación lineal = numpy.percentile (1,75; 3,5; 5,25)');

assert.equal(C.formatearP(0.0004), '<0.001');
assert.equal(C.formatearP(0.0456), '0.046');
assert.equal(C.formatearP(0.05), '0.050');
assert.equal(C.formatearP(null), '—');
assert.equal(C.formatearP(NaN), '—');
assert.equal(C.formatearMediana({ mediana: 1.5, p25: 1.2, p75: 1.84 }, 2), '1.50 (1.20–1.84)');
assert.equal(C.formatearMediana(null), '—');
assert.equal(C.formatearConIC(0.857142, [0.499, 0.973], 2), '0.86 [0.50; 0.97]');
assert.equal(C.formatearConIC(0.857142, null, 2), '0.86');
assert.equal(C.formatearConIC(null, [1, 2]), '—');
ok('formato: p, mediana (IQR) y valor con IC (sin IC si no es estimable)');

assert.equal(C.formatearPrueba({ nombre: 'Mann–Whitney U', estadistico: 36, gl: null, p: 0.034965, metodo: 'exacto' }), 'Mann–Whitney U = 36.00, exacto, p = 0.035');
assert.equal(C.formatearPrueba({ nombre: 't de Welch', estadistico: 2.638459, gl: 10.606977, p: 0.023698, metodo: null }), 't de Welch = 2.64, gl 10.61, p = 0.024');
assert.equal(C.formatearPrueba({ nombre: 'ANOVA de Welch F', estadistico: 9.18, gl: [2, 9.61], p: 0.00589, metodo: null }), 'ANOVA de Welch F = 9.18, gl 2; 9.61, p = 0.006');
assert.equal(C.formatearPrueba({ nombre: 'Kruskal–Wallis H', estadistico: 4.59, gl: 2, p: 0.1005, metodo: null }), 'Kruskal–Wallis H = 4.59, gl 2, p = 0.101');
assert.match(C.formatearPrueba(null), /No estimable/);
ok('formatearPrueba: estadístico, gl, método y p en una línea');

assert.deepEqual([0.1, 0.147, 0.2, 0.33, 0.4, 0.474, -0.5, 1].map(C.magnitudCliff), ['despreciable', 'pequeño', 'pequeño', 'mediano', 'mediano', 'grande', 'grande', 'grande']);
assert.equal(C.magnitudCliff(null), null);
ok('magnitudCliff: umbrales 0,147 / 0,33 / 0,474');

assert.match(C.textoOrientacion(['Sanos', 'Enfermos']), /«Enfermos» tiende a valores mayores que «Sanos» \(referencia\)/);
assert.match(C.textoOrientacion(['A', 'B', 'C']), /referencia: «A»/);
assert.equal(C.textoOrientacion(['A']), '');
const filas = [{ clave: 'a', significativa: true }, { clave: 'b', significativa: false }, { clave: 'c' }];
assert.deepEqual(C.filasVisibles(filas, true).map((f) => f.clave), ['a']);
assert.equal(C.filasVisibles(filas, false).length, 3);
assert.equal(C.filasVisibles(null, true).length, 0);
assert.deepEqual(['sin_variacion', 'omitida', 'no_estimable', 'ok'].map((e) => C.textoEstado({ estado: e })), ['Sin variación', 'Omitida', 'No estimable', '']);
ok('textoOrientacion, filasVisibles y textoEstado');

// --- catálogo ----------------------------------------------------------------------------------
const info = C.infoCaracteristica('radio_media_mm');
assert.equal(info.etiqueta, 'Media');
assert.equal(info.grupo, 'Radio por arista (mm)');
assert.equal(info.dec, 2);
assert.deepEqual(C.infoCaracteristica('no_existe'), { clave: 'no_existe', grupo: '', etiqueta: 'no_existe', dec: 3, ayuda: '' });
const claves = GRUPOS_METRICAS.flatMap((g) => g.items.map((i) => i.clave));
assert.equal(claves.length, 54);
assert.equal(new Set(claves).size, 54);
assert.ok(claves.every((k) => C.infoCaracteristica(k).grupo !== ''));
ok('infoCaracteristica: las 54 características del catálogo resuelven etiqueta y grupo; lo desconocido cae a su clave');

// --- gráfico -----------------------------------------------------------------------------------
const vg = C.valoresPorGrupo(sujetos, 'radio_media_mm', ['Sanos', 'Enfermos']);
assert.deepEqual(vg, { Sanos: [1.5, 1.7], Enfermos: [2.4, 2.1] });
ok('valoresPorGrupo: descarta null y respeta el orden de los grupos');

assert.deepEqual(C.puntosPorGrupo(sujetos, 'radio_media_mm', ['Sanos', 'Enfermos']), {
  Sanos: [{ valor: 1.5, archivo: 'a.nii' }, { valor: 1.7, archivo: 'b.nii' }],
  Enfermos: [{ valor: 2.4, archivo: 'c.nii' }, { valor: 2.1, archivo: 'd.nii' }],
});
ok('puntosPorGrupo: valor y archivo de cada sujeto con valor');

assert.deepEqual(C.ticksBonitos(0, 1, 4), [0, 0.2, 0.4, 0.6, 0.8, 1]);
const t = C.ticksBonitos(1.2, 9.7, 4);
assert.ok(t.every((x) => x >= 1.2 && x <= 9.7) && t.length >= 3 && t.length <= 7);
assert.deepEqual(C.ticksBonitos(5, 5), [5]);
assert.deepEqual(C.ticksBonitos(NaN, 1), []);
const t2 = C.ticksBonitos(-0.31, 0.42, 4);
assert.ok(t2.includes(0) && t2.every((x) => x >= -0.31 && x <= 0.42));
ok('ticksBonitos: pasos 1/2/5 × 10ⁿ dentro del rango, el cero exacto');

let rg = C.rangoEjeY([2, 4]);
assert.ok(Math.abs(rg.min - 1.84) < 1e-12 && Math.abs(rg.max - 4.16) < 1e-12);
rg = C.rangoEjeY([3, 3, 3]);
assert.ok(rg.min < 3 && rg.max > 3);
assert.deepEqual(C.rangoEjeY([0, 0]), { min: -1, max: 1 });
assert.deepEqual(C.rangoEjeY([]), { min: 0, max: 1 });
ok('rangoEjeY: margen del 8 %; valores iguales o vacío dan un rango válido');

const separacionMinima = (ys, dx) => {
  let m = Infinity;
  for (let i = 0; i < ys.length; i += 1) for (let j = i + 1; j < ys.length; j += 1) m = Math.min(m, Math.hypot(dx[i] - dx[j], ys[i] - ys[j]));
  return m;
};
let semilla = 7;
const azar = () => { semilla = (semilla * 16807) % 2147483647; return semilla / 2147483647; };
const ys = Array.from({ length: 40 }, () => 100 * azar());
const dx = C.enjambre(ys, 3);
assert.deepEqual(C.enjambre(ys, 3), dx);
assert.ok(separacionMinima(ys, dx) >= 6 - 1e-6, 'puntos solapados: ' + separacionMinima(ys, dx));
const iguales = Array(9).fill(50);
const dxIguales = C.enjambre(iguales, 3);
assert.ok(separacionMinima(iguales, dxIguales) >= 6 - 1e-6);
assert.equal(dxIguales[0], 0);
// 9 puntos idénticos con radio 3: cada vecino libre queda a 3 pasos (3 × 0,9 × 3 = 8,1 px) → centro y 4 pares, hasta ±32,4
assert.ok(Math.abs(Math.max(...dxIguales.map(Math.abs)) - 32.4) < 1e-9);
assert.deepEqual(C.enjambre([], 3), []);
assert.deepEqual(C.enjambre([10], 3), [0]);
ok('enjambre: determinista, sin solapes (40 puntos al azar y 9 idénticos), el primero queda en el centro');

console.log('comparacionUtils: todo en orden');
