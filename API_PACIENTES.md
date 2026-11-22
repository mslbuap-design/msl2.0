# API de Pacientes — Contrato para el frontend

> Módulo **Repositorio histórico de pacientes** de MSL Process (Fase 2, verificada en Docker el 2026-11-22).
> Jerarquía: **Paciente → Estudio → Archivo médico**.
> Fuente de verdad del backend: `backend/src/handlers/pacientes.jl` y `backend/database/pacientes_queries.jl`.

---

## 1. Conceptos generales

### URL base

```
http://<host-del-backend>:8000
```

En Docker el frontend (puerto 3000) ya detecta el backend en el **mismo hostname, puerto 8000** (`services/api.js`). Todas las rutas de este documento cuelgan de `/api`.

```js
const API = `${window.location.protocol}//${window.location.hostname}:8000`;
```

### Formato de respuesta

Todas las respuestas JSON (éxito o error) llevan `success`:

```json
{ "success": true,  "paciente": { ... } }
{ "success": false, "error": "Paciente no encontrado", "codigo_error": "NO_ENCONTRADO" }
```

- **`codigo_error`** es estable: úsalo para decidir la lógica (`if (r.codigo_error === "PACIENTE_DUPLICADO")`).
- **`error`** es un texto legible en español: muéstralo al usuario, pero no lo compares (puede cambiar).
- La única respuesta que **no** es JSON es la descarga binaria (`GET /api/archivos/:id/descarga`) cuando sale bien.

### CORS: por qué `PUT` parcial y no `PATCH`

El backend responde a todas las peticiones con:

```
Access-Control-Allow-Origin:  *
Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS
Access-Control-Allow-Headers: Content-Type
```

- `PATCH` **no** está en la lista de métodos permitidos: el navegador bloquearía el *preflight*. Por eso la edición se hace con **`PUT` con semántica parcial** (ver §4): solo se modifican los campos que envías.
- Solo se admite el header personalizado `Content-Type`. No envíes otros headers (`Authorization`, `X-...`) o el preflight fallará.
- Con `FormData` **no** pongas `Content-Type` a mano: el navegador lo genera con el `boundary` correcto.

### Fechas

- Todas las fechas que devuelve la API son **UTC en ISO-8601 con `Z` y sin milisegundos**: `"2026-11-21T10:30:00Z"`. `new Date(valor)` las interpreta correctamente.
- `fecha_estudio` acepta al **enviar**: `"2026-11-21"`, `"2026-11-21T10:30"`, `"2026-11-21T10:30:00"`, `"2026-11-21T10:30:00Z"` o el formato de `Date.toISOString()` (`"2026-11-21T10:30:00.000Z"`). Sin `Z` se interpreta como UTC. Los milisegundos se descartan.
- ⚠️ Una fecha sin hora (`"2026-11-22"`) se guarda como `"2026-11-22T00:00:00Z"`. Para mostrarla sin que cambie de día en zonas como UTC-6, formatea en UTC:
  ```js
  new Date(e.fecha_estudio).toLocaleDateString("es-MX", { timeZone: "UTC" });
  ```

### IDs

- Son enteros positivos de 32 bits (`1 … 2147483647`). Un `:id` no numérico, con signo, con espacios o fuera de rango devuelve **400 `ID_INVALIDO`** (nunca 500).
- Los IDs **pueden saltarse números** (p. ej. un INSERT rechazado consume un valor de la secuencia). No asumas que son consecutivos.

---

## 2. Códigos HTTP y `codigo_error`

| HTTP | `codigo_error` | Cuándo |
|---|---|---|
| 200 | — | Lectura, edición o borrado correctos |
| 201 | — | Recurso creado (paciente, estudio, archivos) |
| 400 | `ID_INVALIDO` | `:id` de la URL no es un entero válido |
| 400 | `DATOS_INVALIDOS` | Body/query inválido: JSON mal formado, campo con tipo incorrecto, `codigo_paciente` inválido, fecha inválida, `limite` fuera de rango, `{}` en un `PUT`, extensión no permitida, archivo vacío, sin archivos… |
| 404 | `NO_ENCONTRADO` | El paciente / estudio / archivo no existe |
| 404 | `ARCHIVO_NO_DISPONIBLE` | El archivo está registrado pero falta en el disco del servidor (solo en descarga) |
| 409 | `PACIENTE_DUPLICADO` | Ya existe un paciente con ese código (**sin distinguir mayúsculas**: `pac-1` = `PAC-1`) |
| 409 | `ARCHIVO_DUPLICADO` | Ya existe un archivo con ese nombre en el estudio, o el nombre viene repetido en la misma subida |
| 413 | `ARCHIVO_MUY_GRANDE` | La subida supera `max_upload_mb` (por defecto 500 MB en total) |
| 500 | `ERROR_INTERNO` | Fallo del servidor. No incluye detalles; se registran en el log del backend |

Una ruta que no existe (o un método no registrado, como `PATCH`) responde **404** `{"success": false, "error": "Ruta no encontrada", "path": "..."}` **sin** `codigo_error`.

Helper sugerido:

```js
async function api(ruta, opciones = {}) {
  const r = await fetch(`${API}${ruta}`, opciones);
  const data = await r.json();
  if (!data.success) {
    const err = new Error(data.error);
    err.status = r.status;
    err.codigo = data.codigo_error ?? null;
    throw err;
  }
  return data;
}

const json = (metodo, body) => ({
  method: metodo,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify(body),
});
```

---

## 3. Modelos JSON

Los campos opcionales vacíos llegan como `null` (nunca se omiten).

### Paciente (completo)

```json
{
  "id_paciente": 1,
  "codigo_paciente": "PAC-001",
  "nombre": "Paciente Ejemplo",
  "datos_clinicos": { "edad": 54, "sexo": "F" },
  "notas": "Texto libre",
  "fecha_creacion": "2026-11-22T06:22:34Z",
  "fecha_actualizacion": "2026-11-22T06:22:47Z"
}
```

En `GET /api/pacientes/:id` y `GET /api/pacientes/codigo/:codigo` lleva además `"estudios": [Estudio + "archivos": [Archivo]]`.

| Campo | Tipo | Reglas |
|---|---|---|
| `codigo_paciente` | string, **obligatorio** | 1–64 caracteres: letras, números, `.`, `_`, `-`; empieza por letra o número; sin `..`, sin `.` final, no puede ser un nombre reservado de Windows (`CON`, `NUL`, `COM1`, `LPT1`…). Único **sin distinguir mayúsculas**; se guarda tal como lo envías. |
| `nombre` | string \| null | ≤ 255 caracteres |
| `datos_clinicos` | objeto JSON \| null | Cualquier objeto `{...}` (no arreglos ni valores sueltos) |
| `notas` | string \| null | ≤ 10 000 caracteres |

Los textos se recortan (`trim`); un texto vacío `""` se guarda como `null`.

### PacienteResumen (solo en el listado)

**No** incluye `datos_clinicos` ni `notas`.

```json
{
  "id_paciente": 1,
  "codigo_paciente": "PAC-001",
  "nombre": "Paciente Ejemplo",
  "fecha_creacion": "2026-11-22T06:22:34Z",
  "fecha_actualizacion": "2026-11-22T06:22:34Z",
  "num_estudios": 2,
  "ultima_fecha_estudio": "2026-11-21T10:30:00Z"
}
```

`ultima_fecha_estudio` es `null` si el paciente no tiene estudios con fecha.

### Estudio

```json
{
  "id_estudio": 1,
  "id_paciente": 1,
  "modalidad": "MRI",
  "fecha_estudio": "2026-11-21T10:30:00Z",
  "descripcion": "RM basal",
  "fecha_creacion": "2026-11-22T06:22:35Z",
  "fecha_actualizacion": "2026-11-22T06:22:35Z"
}
```

En `GET /api/estudios/:id` y dentro del detalle de paciente lleva además `"archivos": [Archivo]`.

| Campo | Tipo | Reglas |
|---|---|---|
| `modalidad` | string \| null | ≤ 255; se guarda en **MAYÚSCULAS** (`"mri"` → `"MRI"`) |
| `fecha_estudio` | string ISO \| null | Ver formatos en §1 |
| `descripcion` | string \| null | ≤ 10 000 |

### Archivo médico

```json
{
  "id_archivo": 1,
  "id_estudio": 1,
  "tipo_archivo": "imagen",
  "formato": "NIfTI",
  "nombre_original": "t1_basal.nii.gz",
  "tamano_bytes": 51228,
  "metadatos_extra": { "secuencia": "T1" },
  "fecha_subida": "2026-11-22T06:22:40Z",
  "fecha_actualizacion": "2026-11-22T06:22:40Z",
  "url_descarga": "/api/archivos/1/descarga"
}
```

- La API **nunca** expone rutas del servidor; usa `url_descarga` (relativa: anteponle `API`).
- `tipo_archivo`: `imagen`, `mascara_roi`, `radiomica`, `estadistica`, `visualizacion`, `reporte`.
- `formato` (se detecta por extensión, sin distinguir mayúsculas):

| Formato | Extensiones |
|---|---|
| `NIfTI` | `.nii.gz`, `.nii` |
| `DICOM` | `.dcm`, `.dicom`, `.ima` |
| `ZIP` | `.zip` (series DICOM empaquetadas) |
| `Excel` | `.xlsx`, `.xls` |
| `CSV` | `.csv` |
| `PNG` | `.png` |
| `PDF` | `.pdf` |

> No dupliques estas listas en el frontend: léelas de `GET /api/pacientes/catalogos`.

---

## 4. Semántica de `PUT` (edición parcial)

| En el body | Efecto |
|---|---|
| Campo **omitido** | No se toca |
| Campo con **`null`** (o `""` en textos) | Se limpia (`null`), si la columna lo admite |
| Campo con valor | Se valida y se reemplaza |
| Body `{}` (ningún campo editable) | **400 `DATOS_INVALIDOS`** |

Campos que **no** admiten `null`: `codigo_paciente` y `tipo_archivo`. Todo `PUT` correcto actualiza `fecha_actualizacion` y devuelve el recurso completo actualizado. Los campos no editables (`id_*`, fechas de sistema, `nombre_original`, `formato`, `tamano_bytes`) se ignoran.

---

## 5. Endpoints

Resumen:

| Método | Ruta | Descripción |
|---|---|---|
| GET | `/api/pacientes/catalogos` | Valores permitidos y límites |
| GET | `/api/pacientes` | Listado paginado y búsqueda |
| POST | `/api/pacientes` | Crear paciente |
| GET | `/api/pacientes/:id` | Paciente + estudios + archivos |
| GET | `/api/pacientes/codigo/:codigo` | Ídem, buscando por código |
| PUT | `/api/pacientes/:id` | Editar paciente (parcial) |
| DELETE | `/api/pacientes/:id` | Borrar paciente (cascada) |
| POST | `/api/pacientes/:id/estudios` | Crear estudio |
| GET | `/api/estudios/:id` | Estudio + archivos |
| PUT | `/api/estudios/:id` | Editar estudio (parcial) |
| DELETE | `/api/estudios/:id` | Borrar estudio (cascada) |
| GET | `/api/estudios/:id/archivos` | Archivos del estudio con filtros |
| POST | `/api/estudios/:id/archivos` | Subir archivos (multipart) |
| GET | `/api/archivos/:id` | Metadatos de un archivo |
| GET | `/api/archivos/:id/descarga` | Descargar bytes |
| PUT | `/api/archivos/:id` | Editar metadatos (parcial) |
| DELETE | `/api/archivos/:id` | Borrar archivo |

### 5.1 `GET /api/pacientes/catalogos`

Cárgalo al iniciar la vista para poblar selects, el `accept` del `<input type="file">` y la paginación.

```json
{
  "success": true,
  "tipos_archivo": ["imagen", "mascara_roi", "radiomica", "estadistica", "visualizacion", "reporte"],
  "formatos": [
    { "formato": "NIfTI", "extensiones": [".nii.gz", ".nii"] },
    { "formato": "DICOM", "extensiones": [".dcm", ".dicom", ".ima"] },
    { "formato": "ZIP",   "extensiones": [".zip"] },
    { "formato": "Excel", "extensiones": [".xlsx", ".xls"] },
    { "formato": "CSV",   "extensiones": [".csv"] },
    { "formato": "PNG",   "extensiones": [".png"] },
    { "formato": "PDF",   "extensiones": [".pdf"] }
  ],
  "max_upload_mb": 500,
  "paginacion": { "limite_defecto": 20, "limite_maximo": 100 }
}
```

```js
const cat = await api("/api/pacientes/catalogos");
const accept = cat.formatos.flatMap(f => f.extensiones).join(",");
```

### 5.2 `GET /api/pacientes?buscar=&limite=&desplazamiento=`

| Query | Por defecto | Reglas |
|---|---|---|
| `buscar` (alias `q`) | — | Subcadena en `codigo_paciente` o `nombre`, sin distinguir mayúsculas. `%` y `_` se buscan literalmente. ≤ 255 caracteres |
| `limite` | 20 | Entero 1–100 (fuera de rango → 400) |
| `desplazamiento` | 0 | Entero ≥ 0 |

Orden: más recientes primero (`fecha_creacion` desc). Respuesta 200:

```json
{
  "success": true,
  "pacientes": [PacienteResumen],
  "total": 37,
  "limite": 20,
  "desplazamiento": 0
}
```

`total` es el número de pacientes que cumplen el filtro (para pintar la paginación: `paginas = Math.ceil(total / limite)`). Sin coincidencias → `pacientes: []`, `total: 0`.

```bash
curl.exe "http://localhost:8000/api/pacientes?limite=5&desplazamiento=0&buscar=PAC"
```

```js
const p = new URLSearchParams({ buscar: texto, limite: 20, desplazamiento: pagina * 20 });
const { pacientes, total } = await api(`/api/pacientes?${p}`);
```

### 5.3 `POST /api/pacientes`

Body JSON: `{ codigo_paciente, nombre?, datos_clinicos?, notas? }` → **201** `{ "success": true, "paciente": Paciente }` (sin `estudios`).

Errores: 400 `DATOS_INVALIDOS`, 409 `PACIENTE_DUPLICADO`.

```bash
curl.exe -X POST http://localhost:8000/api/pacientes -H "Content-Type: application/json" -d "{\"codigo_paciente\":\"PAC-001\",\"nombre\":\"Paciente Ejemplo\",\"datos_clinicos\":{\"edad\":54}}"
```

```js
try {
  const { paciente } = await api("/api/pacientes", json("POST", {
    codigo_paciente: "PAC-001", nombre: "Paciente Ejemplo", datos_clinicos: { edad: 54 },
  }));
} catch (e) {
  if (e.codigo === "PACIENTE_DUPLICADO") mostrarError("Ese código ya existe");
}
```

### 5.4 `GET /api/pacientes/:id` y `GET /api/pacientes/codigo/:codigo`

Devuelven exactamente la misma estructura: **200** `{ "success": true, "paciente": Paciente }` con `estudios` (más reciente primero; los que no tienen fecha al final) y dentro de cada uno sus `archivos` (en orden de subida).

La búsqueda por código es **exacta sin distinguir mayúsculas** (`/codigo/pac-001` encuentra `PAC-001`). Codifica el código con `encodeURIComponent`. Un código con formato inválido → 400 `DATOS_INVALIDOS`.

```json
{
  "success": true,
  "paciente": {
    "id_paciente": 1, "codigo_paciente": "PAC-001", "nombre": "Paciente Ejemplo",
    "datos_clinicos": { "edad": 54 }, "notas": null,
    "fecha_creacion": "2026-11-22T06:22:34Z", "fecha_actualizacion": "2026-11-22T06:22:34Z",
    "estudios": [
      {
        "id_estudio": 1, "id_paciente": 1, "modalidad": "MRI",
        "fecha_estudio": "2026-11-21T10:30:00Z", "descripcion": "RM basal",
        "fecha_creacion": "2026-11-22T06:22:35Z", "fecha_actualizacion": "2026-11-22T06:22:35Z",
        "archivos": [ Archivo ]
      }
    ]
  }
}
```

```js
const { paciente } = await api(`/api/pacientes/codigo/${encodeURIComponent(codigo)}`);
```

### 5.5 `PUT /api/pacientes/:id`

Body (todos opcionales, al menos uno): `{ codigo_paciente?, nombre?, datos_clinicos?, notas? }` → **200** `{ "success": true, "paciente": Paciente }` (sin `estudios`).

Errores: 400 (`{}`, `codigo_paciente: null` o inválido), 404, 409 `PACIENTE_DUPLICADO`.

```js
// Cambia el código y borra las notas; `nombre` y `datos_clinicos` no se tocan.
await api(`/api/pacientes/${id}`, json("PUT", { codigo_paciente: "PAC-001-B", notas: null }));
```

### 5.6 `DELETE /api/pacientes/:id`

Borra el paciente **y en cascada todos sus estudios y archivos** (registros y archivos físicos). Es irreversible: pide confirmación en la UI.

```json
{ "success": true, "eliminado": true, "id_paciente": 1, "limpieza_disco": true }
```

`limpieza_disco: false` significa que el registro **sí** se borró, pero algún archivo no pudo eliminarse del disco (queda en el log del servidor). Para el usuario el borrado es exitoso.

### 5.7 `POST /api/pacientes/:id/estudios`

Body JSON: `{ modalidad?, fecha_estudio?, descripcion? }` (puede ser `{}`) → **201** `{ "success": true, "estudio": Estudio }` (sin `archivos`).

Errores: 400 (fecha inválida, tipos incorrectos), 404 (paciente no existe).

```bash
curl.exe -X POST http://localhost:8000/api/pacientes/1/estudios -H "Content-Type: application/json" -d "{\"modalidad\":\"MRI\",\"fecha_estudio\":\"2026-11-21T10:30:00.000Z\",\"descripcion\":\"RM basal\"}"
```

```js
const { estudio } = await api(`/api/pacientes/${id}/estudios`,
  json("POST", { modalidad: "MRI", fecha_estudio: fecha.toISOString(), descripcion }));
```

### 5.8 `GET /api/estudios/:id`

**200** `{ "success": true, "estudio": Estudio }` con `archivos` incluidos. 404 si no existe.

### 5.9 `PUT /api/estudios/:id`

Body (al menos uno): `{ modalidad?, fecha_estudio?, descripcion? }`; `null` limpia el campo → **200** `{ "success": true, "estudio": Estudio }`.

```js
await api(`/api/estudios/${id}`, json("PUT", { descripcion: "RM control", fecha_estudio: "2026-11-22" }));
```

### 5.10 `DELETE /api/estudios/:id`

Borra el estudio y en cascada sus archivos (BD y disco). Los demás estudios del paciente no se tocan.

```json
{ "success": true, "eliminado": true, "id_estudio": 1, "id_paciente": 1, "limpieza_disco": true }
```

### 5.11 `GET /api/estudios/:id/archivos?tipo_archivo=&formato=`

Filtros opcionales y combinables, sin distinguir mayúsculas (`formato=nifti` ≡ `NIfTI`). Un valor fuera del catálogo → 400. Estudio inexistente → 404; estudio sin archivos → `archivos: []`.

```json
{ "success": true, "id_estudio": 1, "archivos": [Archivo] }
```

```bash
curl.exe "http://localhost:8000/api/estudios/1/archivos?formato=ZIP"
```

### 5.12 `POST /api/estudios/:id/archivos` — subida (`multipart/form-data`)

| Parte | Obligatoria | Descripción |
|---|---|---|
| `file`, `files` o `files[]` | Sí (1 o más) | Archivos. Se pueden repetir para subir varios a la vez |
| `tipo_archivo` | No | Uno del catálogo (sin distinguir mayúsculas). Por defecto `imagen`. Se aplica a **todos** los archivos de la petición |
| `metadatos` | No | Texto JSON con un **objeto** (`{...}`). Se guarda como `metadatos_extra` en **todos** los archivos de la petición |

Respuesta **201**: `{ "success": true, "archivos": [Archivo] }` en el mismo orden en que se enviaron.

**Semántica todo-o-nada:** si cualquier archivo de la petición falla una validación o choca con uno existente, **no se guarda ninguno** (ni en BD ni en disco). El usuario puede corregir y reenviar la petición completa.

Reglas de validación (400 `DATOS_INVALIDOS` salvo que se indique):

- Extensión permitida (ver catálogo) y archivo **no vacío** (0 bytes → 400).
- Nombre sin `/`, `\`, `..`, caracteres de control ni `< > : " | ? *`; sin `.` ni espacio final; no reservado de Windows (`CON.nii`…); ≤ 200 bytes UTF-8.
- El nombre no puede repetirse dentro de la misma petición (comparación sin mayúsculas) → **409 `ARCHIVO_DUPLICADO`**.
- Si en el estudio ya existe un archivo con ese nombre → **409 `ARCHIVO_DUPLICADO`** (nunca se sobrescribe). Para reemplazarlo: `DELETE` y volver a subir. Trata los nombres como insensibles a mayúsculas para evitar sorpresas.
- Tamaño total de la petición > `max_upload_mb` → **413 `ARCHIVO_MUY_GRANDE`**. Valida el tamaño en el cliente antes de enviar.
- Estudio inexistente → 404.
- Como máximo se procesan **2 subidas a la vez** en el servidor; las demás esperan turno (la petición tarda más, no falla).

```bash
curl.exe -X POST http://localhost:8000/api/estudios/1/archivos -F "files=@t1_basal.nii.gz" -F "files=@serie_dicom.zip" -F "tipo_archivo=imagen" -F "metadatos=<meta.json"
```

```js
const fd = new FormData();
for (const f of input.files) fd.append("files", f);   // varios archivos, mismo campo
fd.append("tipo_archivo", "imagen");
fd.append("metadatos", JSON.stringify({ secuencia: "T1", nota: "Lesión \"sospechosa\"" }));

// SIN header Content-Type: el navegador pone multipart/form-data con su boundary.
const { archivos } = await api(`/api/estudios/${idEstudio}/archivos`, { method: "POST", body: fd });
```

Para mostrar progreso de subida usa `XMLHttpRequest` (`xhr.upload.onprogress`); `fetch` no lo expone.

### 5.13 `GET /api/archivos/:id`

**200** `{ "success": true, "archivo": Archivo }`. 404 si no existe.

### 5.14 `GET /api/archivos/:id/descarga`

Devuelve los **bytes exactos** del archivo subido (no JSON). Headers:

| Header | Valor |
|---|---|
| `Content-Type` | `application/gzip` (`.nii.gz`), `application/dicom`, `application/zip`, `application/pdf`, `image/png`, `text/csv; charset=utf-8`, tipos de Excel, o `application/octet-stream` (`.nii`) |
| `Content-Disposition` | `attachment; filename="<ascii>"; filename*=UTF-8''<nombre codificado>` |
| `Content-Length` | Tamaño en bytes |
| `Cache-Control` | `no-store` (datos médicos: no se cachean) |
| `X-Content-Type-Options` | `nosniff` |
| `Access-Control-Expose-Headers` | `Content-Disposition, Content-Length` (para que `fetch` pueda leerlos desde otro origen) |

Errores (en JSON): 400 `ID_INVALIDO`, 404 `NO_ENCONTRADO`, 404 `ARCHIVO_NO_DISPONIBLE` (registrado pero ausente del disco). Comprueba `r.ok` antes de tratar el body como binario.

⚠️ **Límite en RAM:** el servidor todavía no hace *streaming*: carga el archivo completo en memoria antes de enviarlo (hasta 500 MB). Evita lanzar muchas descargas grandes en paralelo.

Opción A — enlace directo (el navegador gestiona la descarga y la memoria):

```js
const a = document.createElement("a");
a.href = `${API}${archivo.url_descarga}`;
a.click();
```

Opción B — `fetch` + `Blob` (útil para pasar los bytes a un visor; ocupa el archivo completo en la memoria del navegador):

```js
const r = await fetch(`${API}${archivo.url_descarga}`);
if (!r.ok) throw await r.json();   // los errores vienen en JSON
const blob = await r.blob();
```

```bash
curl.exe -OJ http://localhost:8000/api/archivos/1/descarga
```

### 5.15 `PUT /api/archivos/:id`

Body (al menos uno): `{ tipo_archivo?, metadatos_extra? }` → **200** `{ "success": true, "archivo": Archivo }`.

- `tipo_archivo` no admite `null`; se normaliza a minúsculas.
- `metadatos_extra` reemplaza el objeto **completo** (no se fusiona); `null` lo borra.
- No renombra ni mueve el archivo físico.

```js
await api(`/api/archivos/${id}`, json("PUT", { tipo_archivo: "reporte", metadatos_extra: { revisado: true } }));
```

### 5.16 `DELETE /api/archivos/:id`

Borra el registro y el archivo físico.

```json
{ "success": true, "eliminado": true, "id_archivo": 2, "limpieza_disco": true }
```

---

## 6. Autenticación (pendiente)

**La API aún no tiene autenticación ni control de acceso.** Cualquier cliente que alcance el puerto 8000 puede leer, descargar y borrar datos de pacientes.

- Úsala solo en redes locales de confianza; no la expongas a internet.
- Cuando se añada autenticación, probablemente se enviará un header `Authorization`. Eso requerirá cambiar `Access-Control-Allow-Headers` en el backend. Centraliza las llamadas en un helper (como `api()` de §2) para añadirlo en un solo lugar.

---

## 7. Flujo típico en la UI

1. Al montar: `GET /api/pacientes/catalogos` y `GET /api/pacientes?limite=20`.
2. Buscar: `GET /api/pacientes?buscar=<texto>&limite=20&desplazamiento=0` (con *debounce*).
3. Abrir un paciente: `GET /api/pacientes/:id` → pinta estudios y archivos anidados.
4. Nuevo estudio: `POST /api/pacientes/:id/estudios` → luego subir archivos a `POST /api/estudios/:id_estudio/archivos`.
5. Tras cualquier `POST`/`PUT`/`DELETE`, usa el recurso devuelto o recarga el detalle del paciente.
