/**
 * Formas de datos compartidas entre el frontend y `server.jl`.
 *
 * Este archivo no exporta nada en tiempo de ejecución: son solo typedefs de
 * JSDoc para tener autocompletado y chequeo básico en el editor sin añadir
 * el toolchain completo de TypeScript. Importar así en cualquier módulo:
 *
 *   /** @typedef {import('../../types.js').FileNode} FileNode *\/
 *
 * Si el backend cambia la forma de una respuesta, este es el único lugar
 * que hay que actualizar para que el editor marque los usos desactualizados.
 */

/**
 * @typedef {Object} FileNode
 * @property {string} name
 * @property {'file'|'folder'} type
 * @property {string} path - Ruta relativa al proyecto (usa '/').
 * @property {string} [fullPath] - Ruta absoluta en disco (solo cuando viene del backend).
 * @property {boolean} [compatible] - Si el archivo es NIfTI/DICOM/Excel compatible.
 * @property {File} [file] - Objeto File del navegador (solo árboles construidos client-side).
 * @property {FileNode[]} [children] - Solo presente en carpetas.
 */

/**
 * @typedef {Object} ProyectoGuardado
 * @property {number} id
 * @property {string} nombre
 * @property {string} ruta_base
 * @property {string} fecha_creacion
 */

/**
 * @typedef {Object} ProyectoDetalle
 * @property {boolean} success
 * @property {string} [error]
 * @property {number} [id]
 * @property {string} [nombre] - Presente en /api/proyecto/:id
 * @property {string} [nombre_proyecto] - Presente en seleccionar-carpeta-local/crear-proyecto
 * @property {string} ruta_proyecto
 * @property {string} [ruta_resultados]
 * @property {FileNode} estructura
 * @property {number} [num_archivos]
 * @property {number} [num_carpetas]
 * @property {string[]} [carpetas_creadas]
 */

/**
 * @typedef {Object} JuliaInfo
 * @property {string} julia_version
 * @property {number} threads
 * @property {number} loaded_images
 * @property {string} temp_dir
 * @property {boolean} native_file_dialog
 * @property {'julia'|'python'} modo_operacion
 */

/**
 * @typedef {Object} SliceState
 * @property {number} num
 * @property {string|null} image - PNG en base64 (data URL).
 */

/**
 * @typedef {Object} RadiomicsResultItem
 * @property {string} archivo
 * @property {boolean} success
 * @property {number} [num_caracteristicas]
 * @property {Object.<string, Object.<string, number|string>>} [caracteristicas]
 * @property {string} [error]
 */

/**
 * @typedef {Object} SelectedTests
 * @property {boolean} tTest
 * @property {boolean} anova
 * @property {boolean} correlation
 * @property {boolean} multipleComparisons
 * @property {boolean} nonParametric
 * @property {boolean} fisherVariance
 * @property {boolean} correlationMatrix
 * @property {boolean} zVariance
 */

export {};
