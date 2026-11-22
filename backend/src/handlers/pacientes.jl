# ==============================================================================
# Handlers del repositorio histórico de pacientes
# (CRUD de pacientes/estudios · subida atómica de archivos médicos)
# ==============================================================================
#
# Jerarquía: Paciente -> Estudio -> Archivo médico (ver SPEC.md).
# Las consultas viven en `PacientesQueries` (database/pacientes_queries.jl);
# aquí solo validamos la entrada HTTP y armamos la respuesta JSON.
#
# Este archivo se incluye desde server.jl en el ámbito `Main`, así que ya
# tiene disponibles `DB_CONN`, `json_response`, `error_response`,
# `leer_body_json`, `registrar_ruta!`, `HTTP`, `JSON3`, `Dates` y
# `PROJECTS_DIR`.
#
# Contrato de errores: TODA respuesta de error lleva `codigo_error` (estable,
# pensado para que el frontend decida qué hacer) además del `error` legible.
# Los 500 nunca devuelven detalles internos: se registran con `@error`.
# ==============================================================================

# =========================================================
# HELPERS DE RESPUESTA DE ERROR
# =========================================================

"""
Igual que `error_response`, pero agrega `"codigo_error"` (p.ej.
`"ID_INVALIDO"`). `merge` combina dos Dicts (si se repite una clave gana el
segundo); `extra` sirve para añadir campos adicionales a la respuesta.
"""
function _error_api(status::Integer, codigo::AbstractString, mensaje::AbstractString;
                    extra::Dict=Dict{String, Any}())
    datos = merge(Dict{String, Any}("codigo_error" => String(codigo)), extra)
    return error_response(status, mensaje; extra=datos)
end

"""
Registra la excepción completa (con stacktrace) en el log del servidor y
responde un 500 genérico. Debe llamarse DENTRO de un bloque `catch`:
`catch_backtrace()` devuelve la traza de la excepción que se está manejando.
`@error` es la macro de logging estándar de Julia (va a stderr).
"""
function _error_interno(contexto::AbstractString, e)
    @error contexto exception = (e, catch_backtrace())
    return _error_api(500, "ERROR_INTERNO", "Error interno del servidor")
end

# =========================================================
# HELPERS DE VALIDACIÓN
# =========================================================

"""
Valida un ID de la URL (`/api/pacientes/:id`). Devuelve el `Int` o `nothing`.
Exige SOLO dígitos ASCII (rechaza `"+5"`, `" 5"`, `"5_0"`, `"٣"`, que
`parse(Int, ...)` aceptaría o trataría raro) y `1 <= id <= typemax(Int32)`,
porque la columna es `SERIAL` (INTEGER de 32 bits): un valor mayor haría
fallar a PostgreSQL con un 500 en lugar de un 400 limpio.
"""
function _id_valido(s::AbstractString)
    (isempty(s) || ncodeunits(s) > 10) && return nothing   # typemax(Int32) tiene 10 dígitos
    all(c -> '0' <= c <= '9', s) || return nothing
    id = parse(Int, s)        # seguro: ≤ 10 dígitos siempre cabe en Int64
    return 1 <= id <= typemax(Int32) ? id : nothing
end
_id_valido(::Any) = nothing   # método de respaldo: cualquier otro tipo es inválido

# Nombres que Windows reserva para dispositivos, con o sin extensión
# ("CON", "con.nii", "LPT1.csv"...). Un `Set` hace la búsqueda O(1).
const _NOMBRES_RESERVADOS_WINDOWS = Set(vcat(
    ["CON", "PRN", "AUX", "NUL", "CONIN\$", "CONOUT\$"],
    ["COM$i" for i in 1:9], ["LPT$i" for i in 1:9],
    ["COM¹", "COM²", "COM³", "LPT¹", "LPT²", "LPT³"],
))

"""
`true` si `nombre` es un nombre reservado de Windows. Windows mira solo la
parte anterior al PRIMER punto y además ignora espacios finales ahí, por eso
`"CON .nii.gz"` también cuenta.
"""
function _nombre_reservado_windows(nombre::AbstractString)
    base = first(split(nombre, '.'))   # `split` siempre devuelve ≥ 1 elemento
    return uppercase(rstrip(base)) in _NOMBRES_RESERVADOS_WINDOWS
end

# Regex del código de paciente: empieza con letra/dígito y después solo
# letras, dígitos, `.`, `_` o `-` (máximo 64 caracteres en total).
# `r"..."` es la sintaxis de Julia para un literal de expresión regular.
const _REGEX_CODIGO_PACIENTE = r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"

"""
`true` si `codigo` es un código de paciente válido: cumple
`_REGEX_CODIGO_PACIENTE`, no contiene `..`, no termina en `.` (Windows lo
eliminaría en silencio) y no es un nombre reservado de Windows. Aunque la
carpeta en disco ya usa el id (`paciente_<id>`), mantenemos el código apto
como nombre de archivo para exportaciones futuras.
"""
function _codigo_paciente_valido(codigo::AbstractString)
    occursin(_REGEX_CODIGO_PACIENTE, codigo) || return false
    occursin("..", codigo) && return false
    endswith(codigo, '.') && return false
    _nombre_reservado_windows(codigo) && return false
    return true
end

"""
Lee del body un campo de texto opcional. Devuelve una tupla `(valor, error)`:
- campo ausente o `null`  -> `(nothing, nothing)`
- texto (se recorta y, si queda vacío, cuenta como `nothing`) -> `(texto, nothing)`
- cualquier otro tipo     -> `(nothing, "mensaje de error")`
Devolver una tupla evita lanzar excepciones para errores esperados del usuario.
"""
function _texto_opcional(body, campo::AbstractString; max_largo::Int=255)
    valor = get(body, campo, nothing)
    isnothing(valor) && return (nothing, nothing)
    valor isa AbstractString || return (nothing, "'$campo' debe ser texto")
    texto = String(strip(valor))
    isempty(texto) && return (nothing, nothing)
    length(texto) > max_largo &&
        return (nothing, "'$campo' excede $max_largo caracteres")
    return (texto, nothing)
end

# Formatos aceptados para `fecha_estudio`:
#   2026-11-21 · 2026-11-21T10:30 · 2026-11-21T10:30:00
#   2026-11-21T10:30:00Z · 2026-11-21T10:30:00.123Z (`Date.toISOString()` de JS)
# Usamos `[0-9]` y no `\d` para no aceptar dígitos Unicode.
const _REGEX_FECHA_ISO =
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}(T[0-9]{2}:[0-9]{2}(:[0-9]{2}(\.[0-9]{1,3})?)?Z?)?$"

"""
Valida una fecha ISO-8601 (ver `_REGEX_FECHA_ISO`) y la devuelve como
`DateTime` en UTC, o `nothing` si es inválida. La `Z` final significa UTC;
sin `Z` también se interpreta como UTC (es lo que guarda la BD). La regex
filtra la FORMA; `Dates.DateTime(texto)` valida los VALORES (mes 13 → error).
`chop` quita el último carácter (la `Z`).
"""
function _parsear_fecha_iso(texto::AbstractString)
    occursin(_REGEX_FECHA_ISO, texto) || return nothing
    sin_z = endswith(texto, 'Z') ? chop(texto) : texto
    dt = try
        Dates.DateTime(sin_z)
    catch
        nothing
    end
    (isnothing(dt) || Dates.year(dt) < 1) && return nothing   # PostgreSQL no admite año 0
    return dt
end

"""
Lee el body JSON y comprueba que sea un objeto (`{...}`). Devuelve
`(body, nothing)` o `(nothing, respuesta_400)` para que el handler pueda
cortar con un `return` temprano.
"""
function _leer_objeto_json(req)
    body = try
        leer_body_json(req)
    catch
        return (nothing, _error_api(400, "DATOS_INVALIDOS", "El body no es JSON válido"))
    end
    body isa JSON3.Object ||
        return (nothing, _error_api(400, "DATOS_INVALIDOS", "El body debe ser un objeto JSON"))
    return (body, nothing)
end

# =========================================================
# POST /api/pacientes
# body: {codigo_paciente, nombre?, datos_clinicos?, notas?}
# =========================================================
function handler_crear_paciente(req, params)
    body, err = _leer_objeto_json(req)
    isnothing(err) || return err

    # --- codigo_paciente (obligatorio) ---
    codigo = get(body, "codigo_paciente", nothing)
    if !(codigo isa AbstractString) || isempty(codigo)
        return _error_api(400, "DATOS_INVALIDOS", "'codigo_paciente' es obligatorio")
    end
    codigo = String(codigo)
    if !_codigo_paciente_valido(codigo)
        return _error_api(400, "DATOS_INVALIDOS",
            "'codigo_paciente' inválido: usa solo letras, números, '.', '_' o '-' " *
            "(sin espacios, '/', '\\' ni '..'; sin '.' final; no puede ser un " *
            "nombre reservado como CON o COM1; máx. 64 caracteres)")
    end

    # --- opcionales de texto ---
    nombre, err = _texto_opcional(body, "nombre")
    isnothing(err) || return _error_api(400, "DATOS_INVALIDOS", err)
    notas, err = _texto_opcional(body, "notas"; max_largo=10_000)
    isnothing(err) || return _error_api(400, "DATOS_INVALIDOS", err)

    # --- datos_clinicos: debe ser un objeto JSON (o ausente/null) ---
    datos_clinicos = get(body, "datos_clinicos", nothing)
    if !isnothing(datos_clinicos) && !(datos_clinicos isa JSON3.Object)
        return _error_api(400, "DATOS_INVALIDOS", "'datos_clinicos' debe ser un objeto JSON")
    end

    try
        # `crear_paciente` ya devuelve el registro completo (INSERT ... RETURNING).
        paciente = crear_paciente(DB_CONN, codigo;
                                  nombre=nombre,
                                  datos_clinicos=datos_clinicos,
                                  notas=notas)
        println("🧑‍⚕️ Paciente creado: $codigo (id $(paciente["id_paciente"]))")
        return json_response(201, Dict("success" => true, "paciente" => paciente))
    catch e
        # Sin pre-chequear con SELECT: dejamos que el índice único de
        # PostgreSQL decida (evita la carrera entre dos requests simultáneos).
        if es_violacion_unica(e)
            return _error_api(409, "PACIENTE_DUPLICADO",
                "Ya existe un paciente con codigo_paciente '$codigo' " *
                "(no se distinguen mayúsculas/minúsculas)")
        end
        return _error_interno("Error creando paciente '$codigo'", e)
    end
end

# =========================================================
# GET /api/pacientes?buscar=...   (alias aceptado: ?q=..., ver SPEC.md)
# =========================================================
function handler_listar_pacientes(req, params)
    try
        # `queryparams` convierte "?buscar=PAC&x=1" en Dict("buscar"=>"PAC","x"=>"1").
        # Decodificar `%zz` (o un `%` suelto) lanza error: es culpa del cliente → 400.
        busqueda = try
            query = HTTP.URIs.queryparams(HTTP.URI(req.target))
            get(query, "buscar", get(query, "q", nothing))
        catch
            return _error_api(400, "DATOS_INVALIDOS", "La URL de la consulta está mal codificada")
        end

        # `isvalid` comprueba que los bytes decodificados sean UTF-8 válido.
        if !isnothing(busqueda) && (!isvalid(busqueda) || length(busqueda) > 255)
            return _error_api(400, "DATOS_INVALIDOS",
                "'buscar' debe ser texto UTF-8 de hasta 255 caracteres")
        end

        pacientes = listar_pacientes(DB_CONN; busqueda=busqueda)
        return json_response(200, Dict("success" => true, "pacientes" => pacientes))
    catch e
        return _error_interno("Error listando pacientes", e)
    end
end

# =========================================================
# POST /api/pacientes/:id/estudios
# body: {modalidad?, fecha_estudio? (ISO-8601), descripcion?}
# =========================================================
function handler_crear_estudio(req, params)
    id_paciente = _id_valido(params["id"])
    isnothing(id_paciente) && return _error_api(400, "ID_INVALIDO", "id de paciente inválido")

    body, err = _leer_objeto_json(req)
    isnothing(err) || return err

    modalidad, err = _texto_opcional(body, "modalidad")
    isnothing(err) || return _error_api(400, "DATOS_INVALIDOS", err)
    # Normalizamos a mayúsculas ("mri" -> "MRI") para que los filtros futuros
    # no dependan de cómo lo escribió cada usuario.
    modalidad = isnothing(modalidad) ? nothing : uppercase(modalidad)

    descripcion, err = _texto_opcional(body, "descripcion"; max_largo=10_000)
    isnothing(err) || return _error_api(400, "DATOS_INVALIDOS", err)

    fecha_texto, err = _texto_opcional(body, "fecha_estudio")
    isnothing(err) || return _error_api(400, "DATOS_INVALIDOS", err)
    fecha_estudio = nothing
    if !isnothing(fecha_texto)
        dt = _parsear_fecha_iso(fecha_texto)
        isnothing(dt) && return _error_api(400, "DATOS_INVALIDOS",
            "'fecha_estudio' debe ser ISO-8601: 'AAAA-MM-DD', 'AAAA-MM-DDTHH:MM:SS' " *
            "o 'AAAA-MM-DDTHH:MM:SS.sssZ' (UTC)")
        fecha_estudio = string(dt)   # texto ISO normalizado (sin Z) para `::timestamp`
    end

    try
        # Sin SELECT previo del paciente: si no existe, la FK de `estudios`
        # rechaza el INSERT (SQLSTATE 23503) y lo traducimos a 404.
        estudio = crear_estudio(DB_CONN, id_paciente;
                                modalidad=modalidad,
                                fecha_estudio=fecha_estudio,
                                descripcion=descripcion)
        println("📋 Estudio $(estudio["id_estudio"]) creado para paciente $id_paciente")
        return json_response(201, Dict("success" => true, "estudio" => estudio))
    catch e
        es_violacion_fk(e) && return _error_api(404, "NO_ENCONTRADO", "Paciente no encontrado")
        return _error_interno("Error creando estudio para paciente $id_paciente", e)
    end
end

# =========================================================
# GET /api/pacientes/:id — paciente + estudios + archivos anidados
# =========================================================
function handler_obtener_paciente(req, params)
    id_paciente = _id_valido(params["id"])
    isnothing(id_paciente) && return _error_api(400, "ID_INVALIDO", "id de paciente inválido")

    try
        paciente = obtener_paciente(DB_CONN, id_paciente)
        isnothing(paciente) && return _error_api(404, "NO_ENCONTRADO", "Paciente no encontrado")

        # Ya vienen ordenados (más reciente primero) desde la query.
        estudios = listar_estudios_paciente(DB_CONN, id_paciente)

        # Una sola consulta para todos los archivos; luego los agrupamos en
        # memoria por id_estudio. `get!(f, dict, clave)` devuelve el vector
        # de esa clave, creándolo con `f()` si todavía no existe.
        archivos_por_estudio = Dict{Int, Vector{Dict{String, Any}}}()
        for archivo in listar_archivos_paciente(DB_CONN, id_paciente)
            lista = get!(() -> Dict{String, Any}[], archivos_por_estudio, archivo["id_estudio"])
            push!(lista, archivo)
        end

        for estudio in estudios
            estudio["archivos"] = get(archivos_por_estudio, estudio["id_estudio"],
                                      Dict{String, Any}[])
        end

        paciente["estudios"] = estudios
        return json_response(200, Dict("success" => true, "paciente" => paciente))
    catch e
        return _error_interno("Error obteniendo paciente $id_paciente", e)
    end
end

# =========================================================
# SUBIDA DE ARCHIVOS MÉDICOS
# =========================================================

# Límite total del body, configurable con la variable de entorno
# `MSL_MAX_UPLOAD_MB` (por defecto 500). Se evalúa UNA vez al cargar el
# archivo; si el valor no es un entero, el servidor falla al arrancar (mejor
# que descubrirlo en plena subida).
const MAX_UPLOAD_BYTES = parse(Int, get(ENV, "MSL_MAX_UPLOAD_MB", "500")) * 1024 * 1024

# Semáforo: como mucho 2 subidas procesándose a la vez. Con `julia -t auto`
# cada request corre en su propio hilo; sin este límite, N subidas grandes
# simultáneas podrían agotar RAM y disco. Las demás esperan su turno.
const UPLOAD_SEMAPHORE = Base.Semaphore(2)

# Campos de texto del formulario: tope de tamaño (no se espera más de 1 MB).
const _MAX_BYTES_CAMPO_TEXTO = 1024 * 1024

# Máximo del nombre de archivo, en bytes. NO es 255 porque el temporal
# `.<nombre>.partial-<16 hex>` añade 26 bytes y el límite de casi todos los
# sistemas de archivos es 255 bytes por nombre.
const _MAX_BYTES_NOMBRE_ARCHIVO = 200

# Tamaño del bloque con el que se copia cada parte a disco (1 MiB).
const _BLOQUE_COPIA = 1024 * 1024

const TIPOS_ARCHIVO_PERMITIDOS =
    ["imagen", "mascara_roi", "radiomica", "estadistica", "visualizacion", "reporte"]

# Extensión -> formato. Es un Vector de pares (y no un Dict) porque el ORDEN
# importa: `.nii.gz` debe probarse antes que `.nii`... y que cualquier otra
# terminación más corta. Un Dict de Julia no garantiza orden de iteración.
const _FORMATOS_POR_EXTENSION = [
    ".nii.gz" => "NIfTI",
    ".nii"    => "NIfTI",
    ".dcm"    => "DICOM",
    ".dicom"  => "DICOM",
    ".ima"    => "DICOM",
    ".zip"    => "ZIP",     # series DICOM empaquetadas
    ".xlsx"   => "Excel",
    ".xls"    => "Excel",
    ".csv"    => "CSV",
    ".png"    => "PNG",
    ".pdf"    => "PDF",
]

# Nombres de campo del formulario que se consideran archivos. `files[]` es
# la convención de muchas librerías JS para enviar varios archivos.
const _CAMPOS_ARCHIVO = ("file", "files", "files[]")

"""
Detecta el formato por extensión, sin distinguir mayúsculas (`ESTUDIO.NII.GZ`
también vale). Devuelve el formato o `nothing` si la extensión no está
permitida. `endswith` compara el final del texto.
"""
function _detectar_formato(nombre::AbstractString)
    nombre_min = lowercase(nombre)
    for (extension, formato) in _FORMATOS_POR_EXTENSION   # desestructura cada par
        endswith(nombre_min, extension) && return formato
    end
    return nothing
end

"""
Valida el nombre que envía el cliente. Devuelve `(nombre, nothing)` o
`(nothing, "mensaje")`. Se rechaza (no se "arregla" en silencio) cualquier
nombre con separadores de ruta, `..`, caracteres de control o reservados de
Windows, punto/espacio final (Windows los quitaría y el nombre en disco no
coincidiría con la BD), nombres de dispositivo (`CON`, `LPT1`...) o
demasiado largo.
"""
function _sanear_nombre_archivo(nombre_crudo::AbstractString)
    nombre = String(nombre_crudo)
    isvalid(nombre) || return (nothing, "Nombre de archivo con codificación inválida (se requiere UTF-8)")
    isempty(strip(nombre)) && return (nothing, "Hay un archivo sin nombre")
    if occursin('/', nombre) || occursin('\\', nombre) || basename(nombre) != nombre
        return (nothing, "Nombre de archivo inválido (contiene separadores de ruta): '$nombre'")
    end
    occursin("..", nombre) &&
        return (nothing, "Nombre de archivo inválido (contiene '..'): '$nombre'")
    # `any(f, texto)` recorre cada carácter; `iscntrl` detecta \0, \n, etc.
    any(c -> iscntrl(c) || c in "<>:\"|?*", nombre) &&
        return (nothing, "Nombre de archivo con caracteres no permitidos: '$nombre'")
    (endswith(nombre, '.') || endswith(nombre, ' ')) &&
        return (nothing, "Nombre de archivo inválido (no puede terminar en '.' ni en espacio): '$nombre'")
    _nombre_reservado_windows(nombre) &&
        return (nothing, "Nombre de archivo reservado por el sistema: '$nombre'")
    ncodeunits(nombre) > _MAX_BYTES_NOMBRE_ARCHIVO &&
        return (nothing, "Nombre de archivo demasiado largo (máx. $_MAX_BYTES_NOMBRE_ARCHIVO bytes): '$nombre'")
    return (nombre, nothing)
end

"""
Tamaño en bytes de una parte multipart SIN copiar su contenido: mueve el
cursor al final (`seekend`), lee la posición y lo devuelve al inicio.
"""
function _tamano_parte(parte)
    io = parte.data
    seekend(io)
    n = position(io)
    seekstart(io)
    return n
end

"""
Copia el contenido de una parte al archivo `destino` en bloques de 1 MiB
(memoria constante, sin crear un `Vector` del tamaño del archivo).
`readbytes!` llena el bloque y devuelve cuántos bytes leyó; `view` evita
copiar el bloque al escribirlo. Devuelve el total de bytes escritos.
"""
function _copiar_parte(destino::IO, parte)
    origen = seekstart(parte.data)   # `seekstart` devuelve el mismo IO
    bloque = Vector{UInt8}(undef, _BLOQUE_COPIA)
    total = 0
    while !eof(origen)
        n = readbytes!(origen, bloque)
        n == 0 && break
        total += write(destino, view(bloque, 1:n))
    end
    return total
end

"""
Borra las rutas indicadas ignorando las que no existan (`force=true`). Un
error al borrar se registra pero no interrumpe la limpieza del resto.
"""
function _borrar_archivos(rutas)
    for ruta in rutas
        try
            rm(ruta; force=true)
        catch e
            @warn "No se pudo borrar $ruta" exception = e
        end
    end
end

"""
Revisa el tamaño de la petición ANTES de parsear el multipart: primero el
header `Content-Length` (lo declara el cliente) y luego el body real.
Devuelve `true` si excede `MAX_UPLOAD_BYTES`.
"""
function _excede_limite_subida(req)
    declarado = tryparse(Int, HTTP.header(req, "Content-Length", ""))
    !isnothing(declarado) && declarado > MAX_UPLOAD_BYTES && return true
    return length(req.body) > MAX_UPLOAD_BYTES
end

_respuesta_muy_grande() = _error_api(413, "ARCHIVO_MUY_GRANDE",
    "La subida excede el límite de $(MAX_UPLOAD_BYTES ÷ (1024 * 1024)) MB")

# =========================================================
# POST /api/estudios/:id/archivos   (multipart/form-data)
# partes: file|files|files[] (1..N archivos), tipo_archivo?, metadatos? (JSON)
# =========================================================
function handler_subir_archivos_estudio(req, params)
    # Chequeos baratos ANTES de esperar turno en el semáforo.
    _excede_limite_subida(req) && return _respuesta_muy_grande()

    id_estudio = _id_valido(params["id"])
    isnothing(id_estudio) && return _error_api(400, "ID_INVALIDO", "id de estudio inválido")

    # `acquire` bloquea hasta que haya un cupo libre; `finally` garantiza el
    # `release` pase lo que pase (return temprano o excepción), si no el
    # cupo quedaría ocupado para siempre.
    Base.acquire(UPLOAD_SEMAPHORE)
    try
        return _procesar_subida(req, id_estudio)
    catch e
        return _error_interno("Error inesperado subiendo archivos al estudio $id_estudio", e)
    finally
        Base.release(UPLOAD_SEMAPHORE)
    end
end

"""
Hace el trabajo real de la subida (se llama con el cupo del semáforo ya
tomado). Tres etapas, cada una con su compensación si falla:

1. Escribir cada parte a `.<nombre>.partial-<sufijo>` en la carpeta destino.
   Ningún nombre final existe todavía → nadie ve archivos a medio escribir.
2. Un único `INSERT` multi-fila. `UNIQUE(ruta_relativa)` es el árbitro
   atómico: si otro request ya registró ese nombre, falla TODO el INSERT
   (409) y se borran solo nuestros `.partial`. No hay ventana TOCTOU porque
   no se "pregunta y luego actúa": se actúa y la BD decide.
3. Renombrar cada `.partial` a su nombre final con `mv` (sin `force`, nunca
   sobrescribe). Si falla, se deshace todo: archivos movidos, `.partial`
   restantes y las filas recién insertadas.
"""
function _procesar_subida(req, id_estudio::Int)
    # ---------- FASE 1: validar todo, sin tocar el disco ----------

    estudio = obtener_estudio_con_paciente(DB_CONN, id_estudio)
    isnothing(estudio) && return _error_api(404, "NO_ENCONTRADO", "Estudio no encontrado")
    id_paciente = estudio["id_paciente"]::Int   # `::Int` afirma el tipo (falla si no lo es)

    # `parse_multipart_form` devuelve `nothing` si el Content-Type no es
    # multipart/form-data; puede lanzar error si el body está corrupto.
    # Cada parte trae `data` como un IOBuffer sobre `req.body` (no es copia).
    partes = try
        HTTP.parse_multipart_form(req)
    catch
        nothing
    end
    isnothing(partes) && return _error_api(400, "DATOS_INVALIDOS",
        "El body debe ser multipart/form-data válido")

    # Separamos partes de archivo (tienen `filename`) y campos de texto.
    # `similar(partes, 0)` crea un vector vacío del mismo tipo de elemento.
    partes_archivo = similar(partes, 0)
    campos_texto = Dict{String, String}()
    for p in partes
        if isnothing(p.filename)
            # Solo leemos los campos que nos interesan (y la primera vez).
            (p.name in ("tipo_archivo", "metadatos") && !haskey(campos_texto, p.name)) || continue
            _tamano_parte(p) > _MAX_BYTES_CAMPO_TEXTO && return _error_api(400,
                "DATOS_INVALIDOS", "El campo '$(p.name)' es demasiado grande")
            texto = String(read(seekstart(p.data)))
            isvalid(texto) || return _error_api(400, "DATOS_INVALIDOS",
                "El campo '$(p.name)' no es texto UTF-8 válido")
            campos_texto[p.name] = String(strip(texto))
        elseif p.name in _CAMPOS_ARCHIVO
            # Un <input type="file"> sin selección llega como filename="" y
            # 0 bytes: no es un error del usuario, simplemente se ignora.
            (isempty(p.filename) && _tamano_parte(p) == 0) && continue
            push!(partes_archivo, p)
        end
    end
    isempty(partes_archivo) && return _error_api(400, "DATOS_INVALIDOS",
        "No se recibió ningún archivo (usa el campo 'file', 'files' o 'files[]')")

    # --- tipo_archivo (opcional, por defecto "imagen") ---
    tipo_archivo = get(campos_texto, "tipo_archivo", "")
    tipo_archivo = isempty(tipo_archivo) ? "imagen" : lowercase(tipo_archivo)
    tipo_archivo in TIPOS_ARCHIVO_PERMITIDOS || return _error_api(400, "DATOS_INVALIDOS",
        "'tipo_archivo' inválido. Permitidos: $(join(TIPOS_ARCHIVO_PERMITIDOS, ", "))")

    # --- metadatos (opcional, texto JSON que debe ser un objeto) ---
    metadatos = nothing
    texto_metadatos = get(campos_texto, "metadatos", "")
    if !isempty(texto_metadatos)
        metadatos = try
            JSON3.read(texto_metadatos)
        catch
            return _error_api(400, "DATOS_INVALIDOS", "'metadatos' no es JSON válido")
        end
        metadatos isa AbstractDict || return _error_api(400, "DATOS_INVALIDOS",
            "'metadatos' debe ser un objeto JSON ({...})")
    end

    # La carpeta usa SOLO ids numéricos (ya validados): imposible escaparse
    # de PROJECTS_DIR. La ruta relativa se arma con `/` a mano (y no con
    # `joinpath`, que en Windows usaría `\`) para que la BD sea portable.
    carpeta = joinpath(PROJECTS_DIR, "_pacientes", "paciente_$(id_paciente)",
                       "estudio_$(id_estudio)")
    prefijo_relativo = "_pacientes/paciente_$(id_paciente)/estudio_$(id_estudio)"

    # Validamos cada archivo y acumulamos lo necesario para la fase 2.
    # `(; a=1, b=2)` crea una NamedTuple: un registro inmutable y liviano.
    pendientes = NamedTuple[]
    vistos = Set{String}()   # nombres ya usados en ESTA petición (en minúsculas)
    total_bytes = 0
    for parte in partes_archivo
        nombre, err = _sanear_nombre_archivo(parte.filename)
        isnothing(err) || return _error_api(400, "DATOS_INVALIDOS", err)

        formato = _detectar_formato(nombre)
        isnothing(formato) && return _error_api(400, "DATOS_INVALIDOS",
            "Extensión no permitida en '$nombre'. Usa: " *
            join(first.(_FORMATOS_POR_EXTENSION), ", "))

        # Comparamos en minúsculas: en Windows/macOS `A.nii` y `a.nii` son el
        # mismo archivo en disco.
        clave = lowercase(nombre)
        clave in vistos && return _error_api(409, "ARCHIVO_DUPLICADO",
            "El archivo '$nombre' viene repetido en la petición")
        push!(vistos, clave)

        # Tamaño leído directamente de `parte.data`: no se copia nada.
        tamano = _tamano_parte(parte)
        tamano == 0 && return _error_api(400, "DATOS_INVALIDOS", "El archivo '$nombre' está vacío")
        total_bytes += tamano
        total_bytes > MAX_UPLOAD_BYTES && return _respuesta_muy_grande()

        push!(pendientes, (; parte = parte,
                             nombre = nombre,
                             formato = formato,
                             tamano = tamano,
                             ruta_final = joinpath(carpeta, nombre),
                             ruta_relativa = "$prefijo_relativo/$nombre"))
    end

    # ---------- FASE 2a: escribir temporales `.partial` ----------

    try
        mkpath(carpeta)   # crea toda la cadena de carpetas si no existe
    catch e
        return _error_interno("No se pudo crear la carpeta $carpeta", e)
    end

    # Sufijo aleatorio de 64 bits en hexadecimal: dos peticiones simultáneas
    # con el mismo nombre nunca escriben sobre el mismo temporal.
    sufijo = string(rand(UInt64); base=16, pad=16)
    temporales = String[]   # `.partial` creados por ESTA petición (mismo orden que `pendientes`)
    try
        for p in pendientes
            ruta_tmp = joinpath(carpeta, ".$(p.nombre).partial-$(sufijo)")
            push!(temporales, ruta_tmp)   # antes de abrir: así la limpieza lo cubre siempre
            # `open(f, ruta, "w")` abre, llama a `f(io)` y cierra aunque haya error.
            escritos = open(io -> _copiar_parte(io, p.parte), ruta_tmp, "w")
            escritos == p.tamano ||
                error("Escritura incompleta de '$(p.nombre)': $escritos de $(p.tamano) bytes")
        end
    catch e
        _borrar_archivos(temporales)
        return _error_interno("Error escribiendo temporales en $carpeta", e)
    end

    # ---------- FASE 2b: un único INSERT multi-fila (todo o nada) ----------

    registros = [(; tipo_archivo = tipo_archivo,
                    formato = p.formato,
                    nombre_original = p.nombre,
                    ruta_relativa = p.ruta_relativa,
                    tamano_bytes = p.tamano,
                    metadatos_extra = metadatos) for p in pendientes]
    archivos = try
        registrar_archivos_medicos(DB_CONN, id_estudio, registros)
    catch e
        _borrar_archivos(temporales)
        es_violacion_unica(e) && return _error_api(409, "ARCHIVO_DUPLICADO",
            "Ya existe en este estudio un archivo con alguno de esos nombres " *
            "(no se sobrescribe). No se guardó ninguno.")
        # El estudio pudo borrarse entre la fase 1 y este INSERT.
        es_violacion_fk(e) && return _error_api(404, "NO_ENCONTRADO", "Estudio no encontrado")
        return _error_interno("Error registrando archivos del estudio $id_estudio", e)
    end

    # ---------- FASE 2c: publicar (renombrar `.partial` → nombre final) ----------

    movidos = String[]   # finales que ESTA petición creó con `mv`
    fallido = 0
    try
        for (i, p) in enumerate(pendientes)
            fallido = i
            # Sin `force=true`: si el destino ya existe (p.ej. un archivo
            # huérfano en disco, o `A.nii` vs `a.nii` en Windows), `mv` lanza
            # error en vez de sobrescribir.
            mv(temporales[i], p.ruta_final)
            push!(movidos, p.ruta_final)
        end
    catch e
        # Compensación completa: no debe quedar ni archivo sin fila ni fila
        # sin archivo. Los `.partial` ya movidos no existen: `rm(force=true)`
        # simplemente los ignora.
        _borrar_archivos(temporales)
        _borrar_archivos(movidos)
        ids = [a["id_archivo"] for a in archivos]
        try
            eliminar_archivos_medicos(DB_CONN, ids)
        catch e2
            @error "Compensación fallida: filas sin archivo en disco" ids exception = (e2, catch_backtrace())
        end

        p = pendientes[max(fallido, 1)]
        if ispath(p.ruta_final)
            @warn "Existe en disco '$(p.ruta_final)' sin registro en la BD (archivo huérfano o colisión de mayúsculas)"
            return _error_api(409, "ARCHIVO_DUPLICADO",
                "Ya existe en este estudio un archivo '$(p.nombre)' (no se sobrescribe). " *
                "No se guardó ninguno.")
        end
        return _error_interno("Error publicando archivos del estudio $id_estudio", e)
    end

    println("📁 $(length(archivos)) archivo(s) subidos al estudio $id_estudio (paciente $id_paciente)")
    return json_response(201, Dict("success" => true, "archivos" => archivos))
end

# =========================================================
# REGISTRO DE RUTAS
# =========================================================
registrar_ruta!("GET",  "/api/pacientes", handler_listar_pacientes)
registrar_ruta!("POST", "/api/pacientes", handler_crear_paciente)
registrar_ruta!("GET",  "/api/pacientes/:id", handler_obtener_paciente)
registrar_ruta!("POST", "/api/pacientes/:id/estudios", handler_crear_estudio)
registrar_ruta!("POST", "/api/estudios/:id/archivos", handler_subir_archivos_estudio)
