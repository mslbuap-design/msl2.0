# Manual de desarrollo — MSL Process

Este documento es para quien se une al desarrollo de la app. Explica cómo
está organizado el código, qué patrón sigue cada pieza y por qué, y qué deuda
técnica hay que tener presente. Si solo quieres correr la app, ve al
[`README.md`](../README.md).

> Contexto: el backend (`server.jl` y todo `backend/src/`) pasó por un
> refactor reciente que dejó los patrones descritos aquí. Antes de eso,
> `server.jl` era un único archivo de ~900 líneas con una cadena de `elseif`
> por endpoint y estado global compartido entre todos los usuarios del
> servidor (`PROYECTO_ACTUAL`, `LOADED_IMAGES`). Varios comentarios en el
> código todavía hacen referencia a ese "antes", se dejaron a propósito
> porque explican *por qué* la arquitectura actual es como es.

## 1. Mapa de carpetas

```
MSLv2.0/
├── backend/                         Backend Julia (servidor HTTP propio)
│   ├── server.jl                    Punto de entrada: carga módulos, conecta BD, arranca HTTP.serve
│   ├── Project.toml                 Dependencias Julia (equivalente a package.json)
│   ├── ProcesamientoImagenes.jl     Lectura NIfTI/DICOM, extracción de cortes 2D
│   ├── AnalisisRadiomico.jl         Features radiómicas (first-order, GLCM, GLRLM, GLSZM)
│   ├── AnalisisEstadistico.jl       Pruebas estadísticas (t-test, ANOVA, no paramétricas, etc.)
│   ├── database/
│   │   ├── db.jl                    Conexión a PostgreSQL (LibPQ)
│   │   ├── schema.jl                CREATE TABLE (se corre en cada arranque, es idempotente)
│   │   └── queries.jl               Todas las consultas SQL de la app, centralizadas acá
│   ├── src/
│   │   ├── http_utils.jl            Helpers de respuesta HTTP (CORS, JSON, parseo de body)
│   │   ├── router.jl                Tabla de rutas + despachador 
│   │   ├── file_resolver.jl         Resuelve la ruta real en disco de un archivo (namespacing)
│   │   ├── image_cache.jl           Caché de imágenes cargadas, con lock 
│   │   ├── jobs.jl                  Patrón de tareas asíncronas (Threads.@spawn) con progreso
│   │   ├── directory_scan.jl        Escaneo recursivo de la carpeta de un proyecto
│   │   └── handlers/                Un archivo por grupo de endpoints (ver sección 5)
│   │       ├── sistema.jl
│   │       ├── proyectos.jl
│   │       ├── archivos.jl
│   │       ├── visualizacion.jl
│   │       ├── radiomica.jl
│   │       └── estadistica.jl
│   └── scripts/                     Scripts de arranque para modo "escritorio" standalone
│
├── frontend/                         React + Vite
│   └── src/
│       ├── main.jsx                  Monta <App/> dentro de <ProjectProvider>
│       ├── App.jsx                   Shell: decide HomeScreen vs WorkspaceScreen
│       ├── context/ProjectContext.jsx  Estado global compartido (ver sección 9)
│       ├── services/api.js           ÚNICA puerta de salida hacia el backend
│       ├── types.js                   Typedefs JSDoc de las formas de datos compartidas
│       ├── utils/
│       │   ├── fileTree.js            Helpers sobre el árbol de archivos (compatibilidad, filtrado)
│       │   └── format.js
│       ├── hooks/
│       │   ├── useBackendStatus.js    Polling de conexión con Julia
│       │   └── useNativeDialogs.js    Envoltorio sobre prompt/alert/confirm
│       ├── components/                Piezas de UI compartidas (no pertenecen a un módulo)
│       └── modules/                   Un módulo = una pestaña del workspace 
│           ├── visualization/
│           ├── radiomics/
│           ├── statistics/
│           └── graphs/                Reservado, sin implementar
│
├── launcher/                         App standalone alternativa a Docker
├── docker-compose.yml                Orquestación: postgres + backend + frontend
├── Dockerfile.backend / .frontend
├── nginx.conf                        Sirve los estáticos del build de Vite en producción
├── projects/ output/ cache/          Puntos de montaje de los volúmenes Docker (vacíos en el repo)
└── MANUAL_DESARROLLO.md              Este archivo
└── README.md                         
```

## 2. Cómo arranca el backend

`server.jl` carga las cosas en un orden que importa:

1. **Infraestructura (`src/`) primero** — `http_utils.jl`, `file_resolver.jl`,
   `image_cache.jl`, `jobs.jl`, `router.jl`, `directory_scan.jl`. Los módulos
   de dominio y los handlers asumen que nombres como `TEMP_DIR`,
   `json_response` o `registrar_ruta!` ya están en scope.
2. **Base de datos** — `database/db.jl`, `schema.jl`, `queries.jl`. `schema.jl`
   corre `CREATE TABLE IF NOT EXISTS` en cada arranque; no hay sistema de
   migraciones.
3. **`NativeFileDialog.jl` (opcional)** — se intenta cargar con `try/catch`;
   si falla (típico dentro de Docker/Linux headless), la app sigue
   funcionando pero `/api/seleccionar-carpeta-local` responde 501 y el
   frontend cae a su selector de carpetas del navegador (`<input
   webkitdirectory>`).
4. **Módulos de dominio** — `ProcesamientoImagenes.jl`, `AnalisisRadiomico.jl`,
   `AnalisisEstadistico.jl`. Estos son `include()` sueltos, no módulos Julia
   (`module ... end`): sus funciones caen directo en `Main`, que es por lo que
   `AnalisisEstadistico.jl` puede chequear `isdefined(Main, :read_nifti)` para
   saber si `ProcesamientoImagenes.jl` ya se cargó (ver sección 8.3).
5. **Configuración global** — puerto, `PROJECTS_DIR`, conexión a BD. A
   propósito es solo configuración de servidor, nada que dependa de "en qué
   proyecto está trabajando el usuario ahora" (ese fue el bug de
   `PROYECTO_ACTUAL`).
6. **Handlers** (`src/handlers/*.jl`) — cada uno se auto-registra en el
   `Router` al incluirse (ver sección 5).
7. **`HTTP.serve(handle_request, HOST, PORT)`** — `handle_request` en
   `server.jl` es el único punto de entrada: maneja CORS preflight, delega en
   `Router.despachar`, y envuelve todo en un `try/catch` que devuelve 500 en
   vez de tumbar el servidor.

## 3. Los módulos de infraestructura, uno por uno

### `HttpUtils`
`json_response`, `error_response`, `add_cors_headers`, `leer_body_json`,
`parse_int_seguro`. Es el único punto de salida que deberían usar los
handlers — así ningún endpoint nuevo "olvida" los headers CORS.

### `Router`
Tabla de rutas en vez de la cadena de `elseif` original. `registrar_ruta!(metodo,
patron, handler)` registra un endpoint; `patron` soporta segmentos con `:nombre`
(ej. `"/api/proyecto/:id/renombrar"`). `despachar(req)` recorre la tabla y
devuelve `nothing` si nada matchea (el 404 lo arma `server.jl`).

### `FileResolver` — **la pieza más importante para entender el resto**
Antes, todo archivo se ubicaba por `joinpath(TEMP_DIR, filename)`, un único
directorio plano compartido por todo el servidor. Dos proyectos con un
archivo del mismo nombre (`T1.nii`) se pisaban.

Ahora: el frontend manda la ruta **absoluta** del archivo cuando la conoce
(`fullPath`, que viene en cada nodo del árbol que devuelve
`escanear_directorio_recursivo`, dentro del volumen Docker `./projects`).
`resolver_ruta_archivo(archivo)` prioriza:
1. Si ya es una ruta absoluta existente → se usa tal cual.
2. Si no, se busca como nombre de archivo dentro de `TEMP_DIR` (compatibilidad
   con el fallback de navegador — ver sección 9.3).
3. Último recurso: búsqueda recursiva por nombre base dentro de `TEMP_DIR`.

`TEMP_DIR` queda como fallback **exclusivo** para archivos que solo existen
subidos desde el navegador, sin contraparte en disco accesible por el
backend.

### `ImagenesCache`
Reemplaza el `LOADED_IMAGES::Dict` global de antes. La clave ahora es la ruta
absoluta resuelta (única por proyecto, así que ya no hay colisión), y el
acceso está protegido con `ReentrantLock` porque, con `Jobs` corriendo en
tareas propias y HTTP.jl atendiendo requests concurrentes, un `Dict` sin lock
es una condición de carrera real.

### `Jobs` — patrón asíncrono
`analisis-radiomico` y `analisis-estadistico` pueden tardar. En vez de
bloquear el hilo del request de punta a punta:

```julia
job = Jobs.lanzar_job!("radiomico", function (job)
    resultado = hacer_el_trabajo_pesado()
    Jobs.completar_job!(job, resultado)   # o Jobs.fallar_job!(job, "mensaje")
end)
```

`lanzar_job!` lanza `fn(job)` en `Threads.@spawn` y devuelve el `Job`
inmediatamente. El handler HTTP tiene dos modos:
- **Síncrono (default, el que usa el frontend hoy)**: `Jobs.esperar_job(job)`
  bloquea con `wait()` sobre un `Base.Event` — eso sí cede el control al
  scheduler, así que otro usuario abriendo su proyecto no queda en cola
  detrás de un análisis largo.
- **Asíncrono explícito** (`"async": true` en el body): el handler responde
  de inmediato con `job_id`, consultable en `GET /api/jobs/:id`. Ya
  implementado en el backend; el frontend actual no lo usa todavía (no hay
  barra de progreso en la interfaz) — es terreno fértil para una mejora sin
  tocar el backend.

### `directory_scan.jl`
Funciones puras (`escanear_directorio_recursivo`, `contar_archivos`,
`contar_carpetas`) extraídas tal cual del `server.jl` original. Ignora
`Resultados_*`, `.git`, `node_modules`, `.vscode`, `__pycache__` al escanear.

## 4. Cómo agregar un endpoint nuevo

1. Elige (o crea) el archivo correspondiente en `backend/src/handlers/`.
2. Escribe una función `(req, params) -> HTTP.Response`:

```julia
function handler_mi_endpoint(req, params)
    request_data = leer_body_json(req)
    algo = String(get(request_data, "algo", ""))
    # ... lógica ...
    return json_response(200, Dict("success" => true, "resultado" => algo))
end
```

3. Regístralo al final del archivo:

```julia
registrar_ruta!("POST", "/api/mi-endpoint", handler_mi_endpoint)
```

4. Si el archivo de handler es nuevo, agrégalo al `include(...)` en
   `server.jl` (junto a los otros `include(joinpath("src", "handlers", ...))`).
5. Súmalo a `frontend/src/services/api.js` — es la única función que debería
   hablarle al backend desde el frontend.

Nada más necesita tocarse: no hay un archivo central de "todas las rutas" que
editar aparte del propio handler.

## 5. Capa de base de datos

`database/db.jl` abre **una sola conexión global** (`DB_CONN`, creada en
`server.jl`) y la reutiliza en todos los requests — no hay pool de
conexiones. Para el volumen de tráfico de un laboratorio esto es razonable;
si la app creciera a más usuarios concurrentes, un pool sería el primer
cuello de botella a resolver.

`schema.jl` define 6 tablas:

```
proyectos ──< grupos ──< archivos ──< resultados ──< features
                                            │              └─< estadisticas
                                            └─< mascaras (vía archivos)
```

Todo con `ON DELETE CASCADE`: borrar un proyecto borra en cascada
grupos/archivos/resultados/features/estadísticas/máscaras (el handler
`handler_eliminar_proyecto` además borra la carpeta real en disco, por
separado, y reporta si eso falla sin revertir el borrado de BD).

`queries.jl` centraliza todo el SQL de la app — ningún otro archivo debería
construir una consulta a mano. Nota `actualizar_rutas_por_prefijo!`: cuando
se renombra una carpeta, las rutas absolutas guardadas en `archivos.ruta`
quedan obsoletas y hay que recalcularlas, se hace fila por fila en Julia 
para no depender de escapar correctamente el prefijo viejo como patrón 
SQL/regex (rutas de Windows con paréntesis, espacios, etc.).

## 6. Los tres módulos de dominio

### `ProcesamientoImagenes.jl`
Lectura de NIfTI (`NIfTI.jl`, con descompresión manual de `.gz` como
fallback si falla la lectura directa) y DICOM (`DICOM.jl`). Funciones clave:

- `is_compatible_file(filename)` — único lugar que decide qué extensiones
  soporta el backend.
- `extract_slice(data, orientation, slice_num)` — corta un volumen 3D en
  sagital/coronal/axial, con las rotaciones (`rotr90`/`reverse`) necesarias
  para que la orientación se vea correcta en pantalla.
- `matrix_to_base64_png(matrix)` — normaliza a 0-255 y codifica a PNG en
  Base64 (con un PNG 1×1 transparente como último fallback si la conversión
  falla).
- `determinar_ruta_resultados(ruta_proyecto, nombre_proyecto)` — calcula (y
  crea) la carpeta hermana `Resultados_<nombre>/` con subcarpetas
  `radiomics/`, `imagenes/`, `estadisticas/`. Recibe `ruta_proyecto`
  explícito en cada llamada (ya no depende de un "proyecto actual" global).

### `AnalisisRadiomico.jl` (~1300 líneas)
Implementación **pura en Julia** (sin PyCall/Python) de un extractor de
características radiómicas, basado en código MATLAB previo del laboratorio.
Por archivo, calcula:

| Categoría | Qué mide |
|---|---|
| First order | Estadísticas de intensidad (media, varianza, skewness, kurtosis, entropía, percentiles, etc.) |
| Shape | Volumen, área de superficie (aproximada por vóxeles expuestos), esfericidad, compacidad |
| GLCM | Textura de co-ocurrencia de niveles de gris (contraste, correlación, homogeneidad, energía...) |
| GLRLM | Textura de longitud de corrida (run-length) |
| GLSZM | Textura de tamaño de zona (con flood-fill propio para detectar zonas conexas) |

`analizar_radiomico(archivos, modo_paralelo; on_progreso)` es la función
principal: procesa la lista de archivos en paralelo (`Threads.@threads`) o
secuencial, reporta progreso vía el callback (usado por `Jobs`), y arma el
Excel de resultados al final (`guardar_resultados_radiomicos_excel`).

### `AnalisisEstadistico.jl` (~1500 líneas)
`analizar_estadistico(grupos, pruebas, comparar_por_archivos, tipo_datos;
on_progreso)` es la función principal. Flujo:

1. Normaliza los tipos de entrada (todo lo que llega de JSON3 puede venir
   como `JSON3.Object`/`JSON3.Array` en vez de `Dict`/`Vector` — hay
   conversión explícita y bastante `println` de depuración).
2. `extraer_datos_grupos` — por cada grupo, extrae los datos de cada archivo:
   `extraer_datos_excel` (lee una hoja tabulada) o `extraer_datos_imagen`
   (voxeles no nulos, muestreados a 10,000 si hay más, para rendimiento).
3. **Test de normalidad obligatorio** (Shapiro-Wilk) →
   `determinar_parametricidad` decide si el resto corre en modo paramétrico o
   no paramétrico.
4. Ejecuta cada prueba solicitada vía `ejecutar_prueba` (dispatcher por
   nombre de prueba): t-test, Mann-Whitney, ANOVA + Tukey HSD, Kruskal-Wallis,
   correlación (Pearson/Spearman según parametricidad), matriz de
   correlación, pruebas de varianza (Fisher F / Z).
5. Arma el Excel de resultados (`guardar_resultados_estadisticos_excel`).

**Deuda técnica a tener presente**: `extraer_datos_imagen` (línea ~340) tiene
un fallback que, si `read_nifti`/`read_dicom_file` no están definidos en
`Main`, devuelve **datos aleatorios simulados** (`randn(1000) .* 100 .+ 500`)
en vez de fallar. Como ambos módulos se cargan siempre juntos en `server.jl`,
esto no dispara hoy — pero es una trampa si algún día alguno de los dos se
carga de forma independiente (tests unitarios sueltos, por ejemplo): el
análisis "funcionaría" con números inventados sin ningún error visible.

## 7. Frontend: `ProjectContext` como fuente única de verdad

`context/ProjectContext.jsx` concentra: proyecto activo, árbol de archivos,
pestaña activa, selección de archivos/carpetas, y el overlay de "Procesando...".
Ningún módulo (Visualización/Radiómica/Estadística) asume "lo que esté
abierto ahora" por su cuenta — todos reciben este estado explícito vía
`useProjectContext()`. Todas las acciones que hablan con el backend viven acá
también, porque todas terminan mutando este mismo estado compartido.

Puntos a notar:
- `withBusy(mensaje, fn)` envuelve cualquier operación async para mostrar el
  `LoadingOverlay` automáticamente.
- Cuando se abre un proyecto por el selector nativo (`fullPath` disponible en
  cada archivo), no hace falta volver a subir nada: el backend resuelve
  `fullPath` directo. Cuando se cae al selector de navegador
  (`openProjectFromBrowserFileList`), el navegador no expone la ruta real de
  una carpeta elegida por el usuario (restricción de seguridad del propio
  navegador, no arreglable desde el frontend) — por eso `project.ruta` queda
  vacío en ese caso, y `WorkspaceHeader` avisa que "Agregar archivos/grupos"
  no está disponible hasta reabrir el proyecto de otra forma.

## 8. Frontend: patrón de módulo

Cada pestaña del workspace (`visualization`, `radiomics`, `statistics`, y
`graphs` cuando se implemente) sigue el mismo patrón de dos archivos dentro
de `modules/<nombre>/`:

- **`use<Nombre>.js`** — un hook que lee lo que necesita de
  `useProjectContext()` (típicamente `structure`, `selectedFile(s)`,
  `project`), mantiene su propio estado local (parámetros, resultados,
  "corriendo/no corriendo"), y expone funciones de acción (`startX`) que
  llaman a `services/api.js`.
- **`<Nombre>Tab.jsx`** — el componente visual puro, consume el hook y
  renderiza. No le habla al backend directamente.

Esto es intencional: agregar un módulo nuevo no debería requerir tocar
ninguno de los módulos existentes, solo:
1. Crear `modules/<nombre>/use<Nombre>.js` + `<Nombre>Tab.jsx`.
2. Sumar una entrada a la lista `TABS` en `components/WorkspaceScreen.jsx`.
3. Renderizar `<​<Nombre>Tab />` junto a los otros paneles (mismo patrón
   `className={activeTab === 'x' ? '...' : 'hidden'}`, para no perder el
   estado del módulo al cambiar de pestaña).

## 9. Otras piezas del frontend

- **`services/api.js`** — única capa que sabe hablar con el backend.
  Resuelve la URL base en tiempo de ejecución (por hostname del navegador, o
  `VITE_API_URL` en build-time) y configura `axios` con
  `validateStatus: () => true` para que un 400/404/500 con
  `{success:false, error:...}` no se trate como excepción — todo el resto de
  la app espera poder leer `result.success`/`result.error` sin importar el
  status HTTP.
- **`utils/fileTree.js`** — `isCompatibleFile(filename, tab)` es el único
  lugar que decide qué extensiones son válidas por pestaña (hoy: NIfTI/DICOM
  para `visualization`/`radiomics`; + Excel para `statistics`). **No
  contempla `'graphs'` todavía** — hay que decidir y agregar ahí qué formatos
  acepta el módulo de grafos.
- **`types.js`** — typedefs JSDoc de las formas de datos que cruzan la
  frontera frontend/backend (`FileNode`, `ProyectoDetalle`, `JuliaInfo`,
  etc.). No exporta nada en runtime; es solo para autocompletado/chequeo en
  el editor. Si agregas un endpoint nuevo con una forma de respuesta nueva,
  este es el lugar para documentarla.
- **`components/`** — piezas compartidas entre módulos: `FolderTree`
  (árbol recursivo con checkboxes cuando la pestaña activa lo requiere),
  `WorkspaceHeader`, `TabBar`, modales (`AddFilesModal`,
  `ProjectPreviewModal`), `ui/Button` y `ui/EmptyState`.
- **Paleta y tipografía** — `tailwind.config.js` define una paleta "clínica"
  (navy/gris frío + un solo acento teal) y usa IBM Plex Sans/Mono. La clase
  utilitaria `.font-data` (en `index.css`) se usa para todo valor numérico
  (cortes, dimensiones, p-valores, features): es dato, no texto de interfaz.

## 10. Docker y despliegue

`docker-compose.yml` define 3 servicios en la red `msl-network`:

- **`postgres`** — imagen oficial `postgres:16-alpine`, con healthcheck
  (`pg_isready`) del que dependen tanto el backend como (indirectamente) el
  frontend.
- **`backend`** — construido con `Dockerfile.backend` (imagen base
  `julia:1.10`, instala dependencias de `Project.toml`, copia el código,
  corre `julia -t auto --project=. server.jl`). Variables de entorno clave:
  `MSL_SERVER_MODE` (`server` en Docker → escucha en `0.0.0.0`),
  `MSL_PROJECTS_DIR` (`/root/projects`, montado desde `./projects`), y las
  `DB_*` de conexión a Postgres.
- **`frontend`** — build multi-stage (`Dockerfile.frontend`): Node 20 compila
  el build de Vite (`dist/`), y una segunda etapa con `nginx:alpine` sirve
  esos estáticos. `nginx.conf` cachea agresivo los assets con hash
  (`/assets/`) y hace fallback de SPA (`try_files $uri /index.html`) para que
  las rutas del cliente no den 404 al refrescar.

Los tres volúmenes del host (`./projects`, `./output`, `./cache`) son lo
único que hay que respaldar, todo lo demás es reproducible desde el código.

## 11. Convenciones

- **Nombres de dominio en español** (`analizar_radiomico`, `ruta_proyecto`,
  `handler_crear_proyecto`), nombres de infraestructura/Julia-isms en inglés
  cuando corresponden al ecosistema (`Router`, `Jobs`, `FileResolver`). Sigue
  este mismo criterio al agregar código nuevo.
- **Contrato de respuesta uniforme**: todo endpoint devuelve
  `{"success": bool, ...}`, y en error `{"success": false, "error": "..."}`
  (`error_response` en el backend lo garantiza). El frontend en todos lados
  chequea `result.success` antes de usar el resto de la respuesta.
- **`fullPath` es la ruta absoluta real, `path` es relativa al proyecto**
  (con `/` como separador incluso en Windows). Cuando un archivo viene del
  backend siempre trae ambos; cuando se construye client-side (fallback de
  navegador) puede no traer `fullPath`.
- Los módulos de dominio grandes (`AnalisisRadiomico.jl`,
  `AnalisisEstadistico.jl`) están documentados con docstrings de Julia
  (`""" ... """`) antes de cada función — mantener ese estilo si se agregan
  funciones nuevas ahí.

## 12. Deuda técnica y bugs conocidos

1. **Credenciales de PostgreSQL hardcodeadas** en `docker-compose.yml` y como
   default en `backend/database/db.jl` (`msl_user`/`msl_password`). No hay
   `.env` ni secretos de Docker. Aceptable para desarrollo local; **no**
   para cualquier despliegue con datos reales de pacientes accesible más
   allá de una laptop.
2. **Sin autenticación ni autorización** en ningún endpoint. Cualquiera con
   acceso de red al puerto 8000 puede listar, crear, renombrar o **borrar**
   cualquier proyecto (`DELETE /api/proyecto/:id` no pide confirmación del
   lado del servidor).
3. **La "máscara" del análisis radiómico es un umbral trivial** (`volumen .>
   0`), no segmentación real.
4. **Fallback silencioso a datos simulados** en
   `AnalisisEstadistico.extraer_datos_imagen` si `read_nifti`/
   `read_dicom_file` no están en `Main`.
5. **El launcher standalone (`launcher/`) parece código muerto o
   desactualizado**: `launcher-desktop.js` busca el build en
   `frontend/build/` y `launcher-server.js` en `frontend/build-server/`, pero
   Vite (el bundler actual) genera `frontend/dist/` — un remanente de una
   versión anterior basada en Create React App. Además,
   `backend/scripts/start-server.sh` está **vacío**, así que
   `launcher-server.js` fallaría al intentar ejecutarlo. 
6. **`isCompatibleFile` no tiene caso para `'graphs'`** — al conectar el
   módulo de grafos hay que decidir qué extensiones acepta y agregarlo ahí.
7. **Sin tests automatizados** — no hay carpeta `test/` en el backend ni en
   el frontend. `AnalisisEstadistico.jl` tiene una función `test_modulo()` al
   final, pero es un smoke test manual, no parte de un runner de tests.
8. **Sin pool de conexiones a PostgreSQL** — una sola conexión global
   (`DB_CONN`) para todo el servidor (sección 5).
9. **Sin sistema de migraciones de esquema** — `schema.jl` solo hace `CREATE
   TABLE IF NOT EXISTS`; un cambio de columna en una tabla existente hay que
   aplicarlo a mano en cualquier base ya desplegada.
