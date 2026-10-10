import axios from 'axios';

/**
 * Único lugar que sabe hablar con el backend. Ningún componente ni hook
 * debe usar `fetch`/`axios` directamente: todo pasa por las funciones de
 * este módulo, incluido el cálculo de la URL base (antes disperso en
 * `App.js` como la función `JULIA_API`).
 */

/**
 * Resuelve la URL base del backend.
 *
 * Orden de prioridad:
 *  1. `VITE_API_URL` si se definió en build-time (útil para desarrollo con
 *     un backend en otra máquina).
 *  2. Auto-detección por hostname del navegador (igual que el `JULIA_API`
 *     original): localhost/127.0.0.1 -> localhost:8000; cualquier otro
 *     hostname (acceso por IP/red local) -> ese mismo host, puerto 8000.
 *
 * Se resuelve en tiempo de ejecución (no se hornea en el build de Docker),
 * así que la misma imagen sirve tanto para acceso local como desde otras
 * máquinas de la red, sin variables de entorno en el contenedor.
 */
function resolveApiBaseUrl() {
  const envUrl = import.meta.env.VITE_API_URL;
  if (envUrl) return envUrl;

  const { hostname } = window.location;
  if (hostname === 'localhost' || hostname === '127.0.0.1') {
    return 'http://localhost:8000';
  }
  return `http://${hostname}:8000`;
}

export const API_BASE_URL = resolveApiBaseUrl();

// eslint-disable-next-line no-console
console.log('🔌 Backend Julia:', API_BASE_URL);

const client = axios.create({
  baseURL: API_BASE_URL,
  headers: { 'Content-Type': 'application/json' },
  // El backend responde errores "esperables" (validación, 404, conflicto de
  // nombres, etc.) con un status HTTP real (400/404/409/500) y el detalle en
  // el body: {success:false, error:"..."}. Por defecto axios trata cualquier
  // status fuera de 2xx como una excepción y descarta ese body — todo el
  // resto del código de esta app espera poder leer `result.success`/
  // `result.error` sin importar el status (mismo patrón que el `fetch()` del
  // App.js original, que nunca lanza por status). Esto hace que axios se
  // comporte igual: sólo rechaza la promesa ante una falla real de red.
  validateStatus: () => true,
});

/** Convierte un File del navegador a base64 puro (sin el prefijo data:...). */
export function fileToBase64(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result.split(',')[1]);
    reader.onerror = reject;
    reader.readAsDataURL(file);
  });
}

// ============================================================================
// SALUD / INFO
// ============================================================================

/** GET /api/test */
export async function testConnection() {
  const { data } = await client.get('/api/test');
  return data;
}

/** GET /api/info -> JuliaInfo */
export async function getInfo() {
  const { data } = await client.get('/api/info');
  return data;
}

/** POST /api/cambiar-modo */
export async function cambiarModo(modo) {
  const { data } = await client.post('/api/cambiar-modo', { modo });
  return data;
}

// ============================================================================
// PROYECTOS (PostgreSQL)
// ============================================================================

/** GET /api/proyectos -> ProyectoGuardado[] */
export async function listarProyectos() {
  const { data } = await client.get('/api/proyectos');
  return data;
}

/** GET /api/proyecto/:id -> ProyectoDetalle */
export async function abrirProyectoPersistente(id) {
  const { data } = await client.get(`/api/proyecto/${id}`);
  return data;
}

/**
 * DELETE /api/proyecto/:id — elimina el proyecto (fila en BD + carpeta en disco).
 */
export async function eliminarProyecto(id) {
  const { data } = await client.delete(`/api/proyecto/${id}`);
  return data;
}

/**
 * PUT /api/proyecto/:id/renombrar — renombra la carpeta del proyecto en
 * disco Y la fila en la BD en la misma operación (para no repetir el bug
 * de "renombrar desde el explorador de archivos rompe la detección").
 * @param {number} id
 * @param {string} nuevoNombre
 */
export async function renombrarProyecto(id, nuevoNombre) {
  const { data } = await client.put(`/api/proyecto/${id}/renombrar`, { nuevo_nombre: nuevoNombre });
  return data;
}

/**
 * PUT /api/proyecto/:id/carpeta — renombra una carpeta (grupo) dentro de
 * un proyecto.
 * @param {number} id
 * @param {string} carpetaActual - ruta relativa a ruta_proyecto (ej. "Grupo_1")
 * @param {string} nuevoNombre
 */
export async function renombrarCarpetaProyecto(id, carpetaActual, nuevoNombre) {
  const { data } = await client.put(`/api/proyecto/${id}/carpeta`, {
    carpeta_actual: carpetaActual,
    nuevo_nombre: nuevoNombre,
  });
  return data;
}

/** POST /api/seleccionar-carpeta-local -> ProyectoDetalle (o {success:false, usar_fallback:true}) */
export async function seleccionarCarpetaLocal() {
  const { data } = await client.post('/api/seleccionar-carpeta-local');
  return data;
}

/**
 * POST /api/crear-proyecto -> ProyectoDetalle
 * @param {{ruta_base: string, nombre_proyecto: string, num_grupos: number, nombres_grupos?: string[]}} payload
 */
export async function crearProyecto(payload) {
  const { data } = await client.post('/api/crear-proyecto', payload);
  return data;
}

/**
 * POST /api/agregar-grupos
 * @param {{ruta_proyecto: string, num_grupos: number, prefijo?: string}} payload
 */
export async function agregarGrupos(payload) {
  const { data } = await client.post('/api/agregar-grupos', payload);
  return data;
}

/**
 * POST /api/agregar-archivos
 * @param {{ruta_proyecto: string, carpeta_destino: string, nombre_base: string, num_archivos: number, archivos: {data: string, extension: string}[]}} payload
 */
export async function agregarArchivos(payload) {
  const { data } = await client.post('/api/agregar-archivos', payload);
  return data;
}

// ============================================================================
// ARCHIVOS
// ============================================================================

/** POST /api/upload-file — sube un File al TEMP_DIR del servidor. */
export async function uploadFile(file) {
  const base64data = await fileToBase64(file);
  const { data } = await client.post('/api/upload-file', {
    filename: file.name,
    data: base64data,
  });
  return data;
}

/** POST /api/check-file */
export async function checkFile(filename) {
  const { data } = await client.post('/api/check-file', { filename });
  return data;
}

/** DELETE /api/limpiar-cache */
export async function limpiarCache() {
  const { data } = await client.delete('/api/limpiar-cache');
  return data;
}

// ============================================================================
// VISUALIZACIÓN
// ============================================================================

/** POST /api/load-image — `filename` puede ser la ruta absoluta (`fullPath`) del archivo. */
export async function loadImage(filename) {
  const { data } = await client.post('/api/load-image', { filename });
  return data;
}

/**
 * POST /api/get-slice
 * @param {{filename: string, orientation: 'sagittal'|'coronal'|'axial', slice: number}} payload
 */
export async function getSlice(payload) {
  const { data } = await client.post('/api/get-slice', payload);
  return data;
}

/**
 * POST /api/guardar-imagen
 * @param {{nombre_archivo: string, imagen_base64: string, ruta_proyecto?: string}} payload
 */
export async function guardarImagen(payload) {
  const { data } = await client.post('/api/guardar-imagen', payload);
  return data;
}

// ============================================================================
// RADIÓMICA
// ============================================================================

/**
 * POST /api/analisis-radiomico
 * @param {{archivos: string[], modo_paralelo: boolean, ruta_proyecto?: string, async?: boolean}} payload
 */
export async function analisisRadiomico(payload) {
  const { data } = await client.post('/api/analisis-radiomico', payload);
  return data;
}

// ============================================================================
// ESTADÍSTICA
// ============================================================================

/**
 * POST /api/analisis-estadistico
 * @param {{grupos: Object.<string, string[]>, pruebas: string[], comparar_por_archivos: boolean, tipo_datos: 'excel'|'imagenes', ruta_proyecto?: string, async?: boolean}} payload
 */
export async function analisisEstadistico(payload) {
  const { data } = await client.post('/api/analisis-estadistico', payload);
  return data;
}

// ============================================================================
// GRAFOS
// ============================================================================

/**
 * POST /api/analisis-grafos
 * @param {{archivos: string[], tipo_grafo: 'vascular'|'conectividad', opciones?: {bbox?: number[], umbral_higado?: number}, ruta_proyecto?: string, async?: boolean}} payload
 */
export async function analisisGrafos(payload) {
  const { data } = await client.post('/api/analisis-grafos', payload);
  return data;
}

export default {
  API_BASE_URL,
  fileToBase64,
  testConnection,
  getInfo,
  cambiarModo,
  listarProyectos,
  abrirProyectoPersistente,
  eliminarProyecto,
  renombrarProyecto,
  renombrarCarpetaProyecto,
  seleccionarCarpetaLocal,
  crearProyecto,
  agregarGrupos,
  agregarArchivos,
  uploadFile,
  checkFile,
  limpiarCache,
  loadImage,
  getSlice,
  guardarImagen,
  analisisRadiomico,
  analisisEstadistico,
  analisisGrafos,
};
