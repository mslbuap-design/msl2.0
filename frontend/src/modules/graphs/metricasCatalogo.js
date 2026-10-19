/**
 * Catálogo de las características avanzadas que calcula el backend (MetricasGrafos.jl):
 * agrupadas, con etiqueta, decimales y la definición exacta (se muestra como tooltip).
 * Las claves coinciden con `ORDEN_CARACTERISTICAS_GRAFOS` del backend (`avanzadas.caracteristicas`).
 */

const RADIO = 'Radio de cada arista = media, a lo largo de su línea central, de la distancia al fondo (mm): es el radio de la máscara.';

export const GRUPOS_METRICAS = [
  {
    titulo: 'Radio por arista (mm)',
    descripcion: RADIO,
    items: [
      { clave: 'radio_media_mm', etiqueta: 'Media', dec: 2 },
      { clave: 'radio_sd_mm', etiqueta: 'Desv. estándar', dec: 2, ayuda: 'Muestral (n−1).' },
      { clave: 'radio_mediana_mm', etiqueta: 'Mediana', dec: 2 },
      { clave: 'radio_p10_mm', etiqueta: 'Percentil 10', dec: 2 },
      { clave: 'radio_p90_mm', etiqueta: 'Percentil 90', dec: 2 },
      { clave: 'radio_max_mm', etiqueta: 'Máximo', dec: 2 },
      { clave: 'radio_ponderado_mm', etiqueta: 'Media ponderada por longitud', dec: 2, ayuda: 'Σ rᵢ·Lᵢ / Σ Lᵢ: un tramo largo pesa más que uno corto.' },
      { clave: 'radio_terminales_media_mm', etiqueta: 'Media en ramas distales', dec: 2, ayuda: 'Ramas que llegan a una hoja del árbol enraizado.' },
      { clave: 'radio_internas_media_mm', etiqueta: 'Media en ramas internas', dec: 2, ayuda: 'Ramas del árbol enraizado que no llegan a una hoja (incluye el tronco de entrada).' },
    ],
  },
  {
    titulo: 'Longitud por arista (mm)',
    descripcion: 'Longitud de la línea central (suavizada) de cada arista, de nodo a nodo.',
    items: [
      { clave: 'longitud_media_mm', etiqueta: 'Media', dec: 1 },
      { clave: 'longitud_sd_mm', etiqueta: 'Desv. estándar', dec: 1, ayuda: 'Muestral (n−1).' },
      { clave: 'longitud_mediana_mm', etiqueta: 'Mediana', dec: 1 },
      { clave: 'longitud_p10_mm', etiqueta: 'Percentil 10', dec: 1 },
      { clave: 'longitud_p90_mm', etiqueta: 'Percentil 90', dec: 1 },
      { clave: 'longitud_max_mm', etiqueta: 'Máximo', dec: 1 },
      { clave: 'longitud_terminales_media_mm', etiqueta: 'Media en ramas distales', dec: 1 },
      { clave: 'longitud_internas_media_mm', etiqueta: 'Media en ramas internas', dec: 1 },
    ],
  },
  {
    titulo: 'Tortuosidad por arista',
    descripcion:
      'Arco/cuerda de cada arista: longitud de la línea central ÷ distancia en línea recta entre sus nodos (≥ 1; 1 = recta). Solo entran las aristas de al menos la longitud mínima configurada (los tramos de pocos vóxeles son ruidosos).',
    items: [
      { clave: 'tortuosidad_media', etiqueta: 'Media', dec: 3 },
      { clave: 'tortuosidad_sd', etiqueta: 'Desv. estándar', dec: 3, ayuda: 'Muestral (n−1).' },
      { clave: 'tortuosidad_mediana', etiqueta: 'Mediana', dec: 3 },
      { clave: 'tortuosidad_p10', etiqueta: 'Percentil 10', dec: 3 },
      { clave: 'tortuosidad_p90', etiqueta: 'Percentil 90', dec: 3 },
      { clave: 'tortuosidad_max', etiqueta: 'Máximo', dec: 3 },
      { clave: 'tortuosidad_ponderada', etiqueta: 'Media ponderada por longitud', dec: 3, ayuda: 'Σ τᵢ·Lᵢ / Σ Lᵢ.' },
      { clave: 'tortuosidad_n_aristas', etiqueta: 'Aristas incluidas', dec: 0 },
    ],
  },
  {
    titulo: 'Geometría global',
    descripcion: 'Cada arista se aproxima por un cilindro de radio rᵢ y longitud Lᵢ.',
    items: [
      { clave: 'volumen_vascular_mm3', etiqueta: 'Volumen vascular (mm³)', dec: 0, ayuda: 'Σ π·rᵢ²·Lᵢ.' },
      { clave: 'superficie_vascular_mm2', etiqueta: 'Superficie vascular (mm²)', dec: 0, ayuda: 'Σ 2π·rᵢ·Lᵢ (superficie lateral).' },
    ],
  },
  {
    titulo: 'Topología (grado de los nodos)',
    descripcion: 'El grado de un nodo es el número de aristas que lo tocan (un lazo cuenta 2).',
    items: [
      { clave: 'nodos_grado1', etiqueta: 'Puntas (grado 1)', dec: 0 },
      { clave: 'nodos_grado3', etiqueta: 'Bifurcaciones (grado 3)', dec: 0 },
      { clave: 'nodos_grado4', etiqueta: 'Grado 4', dec: 0 },
      { clave: 'nodos_grado5mas', etiqueta: 'Grado ≥ 5', dec: 0 },
      { clave: 'fraccion_trifurcaciones', etiqueta: 'Fracción de uniones de grado ≥ 4', dec: 3, ayuda: 'Uniones de grado ≥ 4 ÷ uniones de grado ≥ 3.' },
    ],
  },
  {
    titulo: 'Jerarquía (Strahler / Horton)',
    descripcion:
      'Cada componente conexa se enraíza en un extremo de su arista de mayor radio (el de menos grafo detrás) y se recorre en anchura; las aristas que cierran un ciclo quedan fuera del árbol.',
    items: [
      { clave: 'n_arboles', etiqueta: 'Árboles (componentes con raíz)', dec: 0 },
      { clave: 'aristas_fuera_del_arbol', etiqueta: 'Aristas fuera del árbol', dec: 0, ayuda: 'Aristas que cierran un ciclo, más lazos propios.' },
      { clave: 'generacion_max', etiqueta: 'Generación máxima', dec: 0, ayuda: 'Generación de una arista = bifurcaciones (≥ 2 hijos) entre la raíz y ella; el tronco de entrada es la generación 0.' },
      { clave: 'generacion_media_puntas', etiqueta: 'Generación media de las ramas distales', dec: 2 },
      { clave: 'strahler_max', etiqueta: 'Orden de Strahler máximo', dec: 0, ayuda: 'Hojas = 1; una unión toma el mayor orden de sus hijas, y +1 si ese mayor se repite.' },
      { clave: 'razon_bifurcacion_horton', etiqueta: 'Razón de bifurcación', dec: 3, ayuda: 'exp(−pendiente de ln Nₖ contra k), con Nₖ = nº de corrientes de orden k. Un árbol binario perfecto da 2.' },
      { clave: 'razon_longitud_horton', etiqueta: 'Razón de longitud', dec: 3, ayuda: 'exp(pendiente de ln lₖ contra k), con lₖ = longitud media de las corrientes de orden k.' },
      { clave: 'razon_radio_horton', etiqueta: 'Razón de radio', dec: 3, ayuda: 'exp(pendiente de ln rₖ contra k), con rₖ = radio medio de las corrientes de orden k.' },
    ],
  },
  {
    titulo: 'Bifurcaciones binarias',
    descripcion:
      'Uniones con exactamente 2 ramas hijas. La dirección de cada rama se mide entre 3 y 6 radios desde la unión (más cerca, el esqueleto se curva y sesga el ángulo).',
    items: [
      { clave: 'n_bifurcaciones_binarias', etiqueta: 'Bifurcaciones binarias', dec: 0 },
      { clave: 'angulo_hijas_media_deg', etiqueta: 'Ángulo entre hijas, media (°)', dec: 1 },
      { clave: 'angulo_hijas_sd_deg', etiqueta: 'Ángulo entre hijas, desv. est. (°)', dec: 1 },
      { clave: 'angulo_hija_mayor_media_deg', etiqueta: 'Ángulo hija mayor–eje (°)', dec: 1, ayuda: 'Ángulo entre la hija de mayor radio y la prolongación de la rama padre.' },
      { clave: 'angulo_hija_menor_media_deg', etiqueta: 'Ángulo hija menor–eje (°)', dec: 1 },
      { clave: 'razon_radios_hijas_media', etiqueta: 'Razón de radios de las hijas', dec: 3, ayuda: 'radio menor ÷ radio mayor (1 = simétrica).' },
      { clave: 'razon_area_media', etiqueta: 'Razón de área', dec: 3, ayuda: '(r₁² + r₂²) ÷ r_padre²: 1 conserva la sección.' },
      { clave: 'exponente_union_mediano', etiqueta: 'Exponente de unión, mediana', dec: 2, ayuda: 'x tal que r_padre^x = r₁^x + r₂^x (ley de Murray: x = 3). No existe si alguna hija ≥ padre.' },
      { clave: 'exponente_union_media', etiqueta: 'Exponente de unión, media', dec: 2 },
      { clave: 'asimetria_particion_media', etiqueta: 'Asimetría de partición', dec: 3, ayuda: '|n₁ − n₂| ÷ (n₁ + n₂ − 2), con nᵢ = puntas en cada subárbol hijo (0 = simétrico, 1 = máxima). Solo uniones con más de 2 puntas.' },
    ],
  },
  {
    titulo: 'Caminos',
    descripcion: 'Distancias medidas a lo largo de las aristas (mm), sobre el árbol de cada componente.',
    items: [
      { clave: 'camino_raiz_punta_media_mm', etiqueta: 'Raíz → punta, media (mm)', dec: 1 },
      { clave: 'camino_raiz_punta_max_mm', etiqueta: 'Raíz → punta, máximo (mm)', dec: 1 },
      { clave: 'diametro_mm', etiqueta: 'Diámetro (mm)', dec: 1, ayuda: 'Mayor distancia entre dos nodos de una misma componente.' },
      { clave: 'camino_medio_mm', etiqueta: 'Distancia media entre nodos (mm)', dec: 1, ayuda: 'Promedio sobre todos los pares de nodos de una misma componente (índice de Wiener normalizado).' },
    ],
  },
];

/** Número con `dec` decimales, o '—' si no hay valor. */
export function formatearMetrica(valor, dec = 2) {
  return typeof valor === 'number' && Number.isFinite(valor) ? valor.toFixed(dec) : '—';
}
