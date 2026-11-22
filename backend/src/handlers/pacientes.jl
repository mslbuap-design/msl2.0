# ==============================================================================
# Handlers del repositorio histórico de pacientes
# (CRUD de pacientes/estudios · subida atómica de archivos médicos ·
#  subida fragmentada para archivos de varios GB · descarga con `Range`)
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

# Mensaje compartido por POST y PUT para que el usuario vea la misma regla.
const _MENSAJE_CODIGO_INVALIDO =
    "'codigo_paciente' inválido: usa solo letras, números, '.', '_' o '-' " *
    "(sin espacios, '/', '\\' ni '..'; sin '.' final; no puede ser un " *
    "nombre reservado como CON o COM1; máx. 64 caracteres)"

"""
`true` si el body JSON trae la clave `campo`, AUNQUE su valor sea `null`.
Así distinguimos "campo omitido" (no se cambia) de "campo = null" (limpiar).
`JSON3.Object` guarda las claves como `Symbol`, por eso `Symbol(campo)`.
"""
_campo_presente(body, campo::AbstractString) = haskey(body, Symbol(campo))

"""
Lee los parámetros `?clave=valor` de la URL. Devuelve `(Dict, nothing)` o
`(nothing, respuesta_400)` si la URL está mal codificada (`%zz`) o algún
valor decodificado no es UTF-8 válido.
"""
function _leer_query(req)
    query = try
        HTTP.URIs.queryparams(HTTP.URI(req.target))
    catch
        return (nothing, _error_api(400, "DATOS_INVALIDOS", "La URL de la consulta está mal codificada"))
    end
    all(isvalid, values(query)) ||
        return (nothing, _error_api(400, "DATOS_INVALIDOS",
            "Los parámetros de la URL deben ser texto UTF-8 válido"))
    return (query, nothing)
end

"""
Lee un entero de la query (`?limite=20`). Devuelve `(valor, nothing)` o
`(nothing, "mensaje")`. Ausente → `defecto`. Exige solo dígitos ASCII (como
`_id_valido`) y usa `tryparse`, que devuelve `nothing` en vez de lanzar
error si el número no cabe en un `Int`. `maximo=nothing` = sin tope.
"""
function _entero_query(query, nombre::AbstractString, defecto::Int, minimo::Int,
                       maximo::Union{Int, Nothing}=nothing)
    texto = get(query, nombre, nothing)
    isnothing(texto) && return (defecto, nothing)
    n = (!isempty(texto) && all(c -> '0' <= c <= '9', texto)) ? tryparse(Int, texto) : nothing
    if isnothing(n) || n < minimo || (!isnothing(maximo) && n > maximo)
        rango = isnothing(maximo) ? ">= $minimo" : "entre $minimo y $maximo"
        return (nothing, "'$nombre' debe ser un entero $rango")
    end
    return (n, nothing)
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
    _codigo_paciente_valido(codigo) ||
        return _error_api(400, "DATOS_INVALIDOS", _MENSAJE_CODIGO_INVALIDO)

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
# GET /api/pacientes?buscar=...&limite=20&desplazamiento=0
# (alias aceptado: ?q=... en lugar de ?buscar=...)
# =========================================================

# Paginación del listado. También se publican en /api/pacientes/catalogos
# para que el frontend nunca se desincronice de estos valores.
const LIMITE_PACIENTES_DEFECTO = 20
const LIMITE_PACIENTES_MAXIMO  = 100

function handler_listar_pacientes(req, params)
    # `queryparams` convierte "?buscar=PAC&x=1" en Dict("buscar"=>"PAC","x"=>"1").
    query, err = _leer_query(req)
    isnothing(err) || return err

    busqueda = get(query, "buscar", get(query, "q", nothing))
    if !isnothing(busqueda) && length(busqueda) > 255
        return _error_api(400, "DATOS_INVALIDOS", "'buscar' admite hasta 255 caracteres")
    end

    limite, err = _entero_query(query, "limite", LIMITE_PACIENTES_DEFECTO,
                                1, LIMITE_PACIENTES_MAXIMO)
    isnothing(err) || return _error_api(400, "DATOS_INVALIDOS", err)
    desplazamiento, err = _entero_query(query, "desplazamiento", 0, 0)
    isnothing(err) || return _error_api(400, "DATOS_INVALIDOS", err)

    try
        # `; busqueda, limite` es azúcar de Julia para `busqueda=busqueda, ...`.
        resultado = listar_pacientes(DB_CONN; busqueda, limite, desplazamiento)
        return json_response(200, Dict(
            "success"        => true,
            "pacientes"      => resultado.pacientes,
            "total"          => resultado.total,
            "limite"         => limite,
            "desplazamiento" => desplazamiento
        ))
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

"""
Completa `paciente` (Dict) con `estudios` y, dentro de cada estudio, sus
`archivos`. El `!` del nombre es la convención de Julia para "modifica su
argumento". Lo comparten `GET /api/pacientes/:id` y
`GET /api/pacientes/codigo/:codigo` para que ambas respuestas sean idénticas.
"""
function _anidar_estudios_y_archivos!(paciente::AbstractDict)
    id_paciente = paciente["id_paciente"]::Int

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
    return paciente
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
        _anidar_estudios_y_archivos!(paciente)
        return json_response(200, Dict("success" => true, "paciente" => paciente))
    catch e
        return _error_interno("Error obteniendo paciente $id_paciente", e)
    end
end

# =========================================================
# GET /api/pacientes/codigo/:codigo — igual que /:id, buscando por código
# (exacto, sin distinguir mayúsculas)
# =========================================================
function handler_obtener_paciente_por_codigo(req, params)
    # El router entrega el segmento tal cual viene en la URL; lo decodificamos
    # (`%41` → `A`). Si la decodificación falla, el código es inválido.
    codigo = try
        HTTP.URIs.unescapeuri(params["codigo"])
    catch
        nothing
    end
    # `isvalid` va primero: la regex no debe recibir UTF-8 corrupto.
    if isnothing(codigo) || !isvalid(codigo) || !_codigo_paciente_valido(codigo)
        return _error_api(400, "DATOS_INVALIDOS", _MENSAJE_CODIGO_INVALIDO)
    end

    try
        paciente = obtener_paciente_por_codigo(DB_CONN, codigo)
        isnothing(paciente) && return _error_api(404, "NO_ENCONTRADO", "Paciente no encontrado")
        _anidar_estudios_y_archivos!(paciente)
        return json_response(200, Dict("success" => true, "paciente" => paciente))
    catch e
        return _error_interno("Error obteniendo paciente con código '$codigo'", e)
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
# SUBIDA FRAGMENTADA (chunked upload) — archivos de 500 MB a varios GB
# =========================================================
#
# Flujo:
#   1. POST   /api/estudios/:id/subidas            → abre sesión + `.partial` vacío
#   2. PUT    /api/subidas/:id_subida/parte?indice=N (una vez por parte, en
#             cualquier orden; reintentar una parte es seguro)
#   3. POST   /api/subidas/:id_subida/completar    → registra en BD y publica con `mv`
#   (DELETE   /api/subidas/:id_subida cancela)
#
# Cada petición trae como mucho CHUNK_SIZE_BYTES, así la RAM por petición
# queda acotada aunque el archivo pese varios GB. HTTP.jl ya tiene el body
# completo en `req.body` cuando llega al handler; por eso el tamaño de parte
# es lo que de verdad limita la memoria.
#
# Concurrencia (con `julia -t auto` cada request corre en su propio hilo):
#   - `_SUBIDAS_LOCK` protege el Dict global de sesiones (acceso breve).
#   - `sesion.lock` serializa las operaciones sobre UNA sesión (escribir parte,
#     completar, cancelar, expirar).
#   - Orden de locks: si se necesitan ambos, SIEMPRE primero el de la sesión y
#     después el global. Nunca al revés → no hay interbloqueos (deadlocks).

import Random   # stdlib: `RandomDevice` entrega bytes aleatorios del sistema operativo

const _BYTES_POR_MB = 1024 * 1024

# Tamaño de cada parte (25 MB por defecto). Configurable con MSL_CHUNK_SIZE_MB.
const CHUNK_SIZE_BYTES = parse(Int, get(ENV, "MSL_CHUNK_SIZE_MB", "25")) * 1024 * 1024
CHUNK_SIZE_BYTES > 0 || error("MSL_CHUNK_SIZE_MB debe ser un entero positivo")

# Tamaño máximo de UN archivo fragmentado (5 GB). `Int64` explícito: el valor
# no cabría en un entero de 32 bits.
const MAX_CHUNKED_UPLOAD_BYTES =
    parse(Int64, get(ENV, "MSL_MAX_CHUNKED_UPLOAD_MB", "5120")) * Int64(1024 * 1024)

# Como mucho 4 partes escribiéndose a la vez (≈ 100 MB de partes en proceso).
const CHUNK_UPLOAD_SEMAPHORE = Base.Semaphore(4)

# Una sola lectura grande (>= 100 MiB) a la vez: dos descargas de ~1 GB en
# paralelo podrían tumbar un contenedor de 4 GB.
const LARGE_DOWNLOAD_SEMAPHORE = Base.Semaphore(1)
const UMBRAL_DESCARGA_GRANDE_BYTES = 100 * _BYTES_POR_MB

# A partir de este tamaño el frontend debería usar la subida fragmentada.
const UMBRAL_SUBIDA_FRAGMENTADA_MB = 100

# Una sesión expira tras 2 h SIN actividad (cada parte recibida renueva el plazo).
const EXPIRACION_SUBIDA = Dates.Hour(2)

const _REGEX_ID_SUBIDA = r"^[0-9a-f]{32}$"

# Formato ISO-8601 UTC con `Z`, igual que el resto de la API.
const _FORMATO_EXPIRA = Dates.DateFormat("yyyy-mm-dd\\THH:MM:SS")

"""
Estado de una subida fragmentada en curso. Es `mutable struct` porque
algunos campos cambian (`expira`, `activa`); los marcados con `const`
(Julia ≥ 1.8) no se pueden reasignar después de crear la sesión. Ojo:
`recibidas` es `const` (siempre el mismo vector), pero su CONTENIDO sí cambia.
Vive solo en memoria: si el servidor se reinicia, las sesiones se pierden y
sus `.partial` se borran por antigüedad (ver `_limpiar_subidas_vencidas!`).
"""
mutable struct SesionSubida
    const id_subida::String
    const id_estudio::Int
    const nombre_original::String
    const formato::String
    const tipo_archivo::String
    const metadatos::Any                # objeto JSON o `nothing`
    const tamano_bytes::Int64
    const total_partes::Int
    const ruta_tmp::String
    const recibidas::BitVector          # recibidas[i] == true → llegó la parte i-1
    const lock::ReentrantLock
    expira::Dates.DateTime              # UTC
    activa::Bool                        # false tras completar/cancelar/expirar
end

const _SUBIDAS_ACTIVAS = Dict{String, SesionSubida}()
const _SUBIDAS_LOCK = ReentrantLock()

# Carpeta temporal DENTRO del mismo volumen que los archivos finales: así
# `mv` es un simple renombrado atómico (no una copia de 1 GB).
_carpeta_tmp_subidas() = joinpath(PROJECTS_DIR, "_pacientes", "_tmp_subidas")

"128 bits aleatorios del sistema operativo en hexadecimal (32 caracteres): imposible de adivinar."
_nuevo_id_subida() = bytes2hex(rand(Random.RandomDevice(), UInt8, 16))

_ahora_utc() = Dates.now(Dates.UTC)
_vencida(s::SesionSubida) = _ahora_utc() > s.expira
_expira_texto(s::SesionSubida) = Dates.format(s.expira, _FORMATO_EXPIRA) * "Z"

"""
Bytes que DEBE traer la parte `indice` (base 0): todas miden
`CHUNK_SIZE_BYTES` salvo la última, que lleva el residuo exacto.
"""
function _tamano_esperado_parte(s::SesionSubida, indice::Integer)
    indice < s.total_partes - 1 && return CHUNK_SIZE_BYTES
    return Int(s.tamano_bytes - Int64(s.total_partes - 1) * Int64(CHUNK_SIZE_BYTES))
end

"""
Bytes crudos del body SIN copiarlos cuando es posible. En la versión de
HTTP.jl instalada `req.body` no es un `Vector{UInt8}` sino un
`HTTP.BytesBody` (envoltorio con campos `data` y `next_index`); su
documentación permite "tomar prestado" `view(data, next_index:end)` para
solo leer. `view` crea una ventana sobre el vector original (sin copiar los
25 MB). Para cualquier otro tipo de body (p.ej. `EmptyBody`), `copy`
devuelve un `Vector{UInt8}`.
"""
function _bytes_del_body(body)
    body isa AbstractVector{UInt8} && return body
    if hasproperty(body, :data) && hasproperty(body, :next_index) &&
       body.data isa AbstractVector{UInt8}
        return view(body.data, body.next_index:length(body.data))
    end
    return copy(body)
end

_subida_no_encontrada() = _error_api(404, "SUBIDA_NO_ENCONTRADA",
    "La subida no existe, ya terminó, fue cancelada o expiró (2 h sin actividad)")

"""
Busca una sesión por su id (tomando el lock global solo un instante).
Devuelve la sesión o `nothing` si el id tiene formato inválido, no existe o
ya venció (`incluir_vencidas=true` la devuelve igual, para poder cancelarla).
`lock(f, l)` ejecuta `f()` con el lock tomado y lo libera aunque haya error.
"""
function _buscar_sesion(id_texto::AbstractString; incluir_vencidas::Bool=false)
    occursin(_REGEX_ID_SUBIDA, id_texto) || return nothing
    s = lock(() -> get(_SUBIDAS_ACTIVAS, String(id_texto), nothing), _SUBIDAS_LOCK)
    isnothing(s) && return nothing
    (!incluir_vencidas && _vencida(s)) && return nothing
    return s
end

"""
Cierra la sesión: la marca inactiva, la quita del Dict global y borra su
`.partial` (si ya se movió, `rm(force=true)` simplemente no hace nada).
Debe llamarse con `s.lock` YA tomado. Es idempotente.
"""
function _cerrar_sesion!(s::SesionSubida)
    s.activa = false
    lock(() -> delete!(_SUBIDAS_ACTIVAS, s.id_subida), _SUBIDAS_LOCK)
    _borrar_archivos((s.ruta_tmp,))
    return nothing
end

"""
Limpieza "perezosa" (se ejecuta al iniciar cada subida nueva):
1. Cierra las sesiones vencidas y borra sus `.partial`.
2. Borra `.partial` huérfanos (sin sesión en memoria, p.ej. tras reiniciar el
   servidor) cuya última modificación tenga más de 2 h.
Nunca lanza error: un fallo aquí no debe impedir iniciar una subida.
"""
function _limpiar_subidas_vencidas!()
    try
        # Paso 1a: solo LEER el Dict con el lock global...
        candidatas = lock(_SUBIDAS_LOCK) do
            [s for s in values(_SUBIDAS_ACTIVAS) if _vencida(s)]
        end
        # Paso 1b: ...y cerrar cada una con SU lock (respeta el orden sesión → global).
        # Se vuelve a comprobar: una parte pudo renovar el plazo mientras tanto.
        for s in candidatas
            lock(s.lock) do
                (s.activa && _vencida(s)) && _cerrar_sesion!(s)
            end
        end

        # Paso 2: huérfanos en disco.
        carpeta = _carpeta_tmp_subidas()
        isdir(carpeta) || return nothing
        activos = lock(() -> Set(keys(_SUBIDAS_ACTIVAS)), _SUBIDAS_LOCK)
        limite = time() - Dates.value(Dates.Second(EXPIRACION_SUBIDA))   # `time()` = segundos Unix
        for nombre in readdir(carpeta)
            endswith(nombre, ".partial") || continue
            chop(nombre; tail=length(".partial")) in activos && continue
            ruta = joinpath(carpeta, nombre)
            mtime(ruta) < limite && _borrar_archivos((ruta,))
        end
    catch e
        @warn "Fallo limpiando subidas vencidas" exception = e
    end
    return nothing
end

"Forma pública de la sesión (nunca expone `ruta_tmp`)."
function _sesion_publica(s::SesionSubida)
    return Dict{String, Any}(
        "id_subida"          => s.id_subida,
        "id_estudio"         => s.id_estudio,
        "nombre_original"    => s.nombre_original,
        "formato"            => s.formato,
        "tipo_archivo"       => s.tipo_archivo,
        "tamano_bytes"       => s.tamano_bytes,
        "tamano_parte_bytes" => CHUNK_SIZE_BYTES,
        "total_partes"       => s.total_partes,
        "expira_en"          => _expira_texto(s)
    )
end

# =========================================================
# POST /api/estudios/:id/subidas
# body JSON: {nombre_original, tamano_bytes, tipo_archivo?, metadatos?}
# =========================================================
function handler_iniciar_subida(req, params)
    id_estudio = _id_valido(params["id"])
    isnothing(id_estudio) && return _error_api(400, "ID_INVALIDO", "id de estudio inválido")

    body, err = _leer_objeto_json(req)
    isnothing(err) || return err

    # --- nombre_original (obligatorio, mismas reglas que la subida directa) ---
    nombre_crudo = get(body, "nombre_original", nothing)
    (nombre_crudo isa AbstractString && !isempty(nombre_crudo)) ||
        return _error_api(400, "DATOS_INVALIDOS", "'nombre_original' es obligatorio")
    nombre, err = _sanear_nombre_archivo(nombre_crudo)
    isnothing(err) || return _error_api(400, "DATOS_INVALIDOS", err)
    formato = _detectar_formato(nombre)
    isnothing(formato) && return _error_api(400, "DATOS_INVALIDOS",
        "Extensión no permitida en '$nombre'. Usa: " * join(first.(_FORMATOS_POR_EXTENSION), ", "))

    # --- tamano_bytes (entero 1..MAX) ---
    # En Julia `Bool <: Integer` (`true == 1`), por eso se excluye a mano.
    tamano = get(body, "tamano_bytes", nothing)
    (tamano isa Integer && !(tamano isa Bool) && tamano >= 1) ||
        return _error_api(400, "DATOS_INVALIDOS", "'tamano_bytes' debe ser un entero >= 1")
    tamano > MAX_CHUNKED_UPLOAD_BYTES && return _error_api(413, "ARCHIVO_MUY_GRANDE",
        "El archivo excede el límite de $(MAX_CHUNKED_UPLOAD_BYTES ÷ _BYTES_POR_MB) MB")
    tamano = Int64(tamano)

    # --- tipo_archivo (opcional, por defecto "imagen") ---
    tipo_crudo = get(body, "tipo_archivo", nothing)
    (isnothing(tipo_crudo) || tipo_crudo isa AbstractString) ||
        return _error_api(400, "DATOS_INVALIDOS", "'tipo_archivo' debe ser texto")
    tipo_archivo = (isnothing(tipo_crudo) || isempty(strip(tipo_crudo))) ? "imagen" :
                   lowercase(strip(tipo_crudo))
    tipo_archivo in TIPOS_ARCHIVO_PERMITIDOS || return _error_api(400, "DATOS_INVALIDOS",
        "'tipo_archivo' inválido. Permitidos: $(join(TIPOS_ARCHIVO_PERMITIDOS, ", "))")

    # --- metadatos (opcional, objeto JSON) ---
    metadatos = get(body, "metadatos", nothing)
    (isnothing(metadatos) || metadatos isa AbstractDict) ||
        return _error_api(400, "DATOS_INVALIDOS", "'metadatos' debe ser un objeto JSON ({...})")

    try
        isnothing(obtener_estudio_con_paciente(DB_CONN, id_estudio)) &&
            return _error_api(404, "NO_ENCONTRADO", "Estudio no encontrado")
        # Pre-chequeo NO autoritativo (el árbitro real es el UNIQUE en
        # `completar`): evita que el usuario suba 1 GB para recibir un 409 al final.
        nombre_min = lowercase(nombre)
        any(a -> lowercase(a["nombre_original"]) == nombre_min,
            listar_archivos_estudio(DB_CONN, id_estudio)) &&
            return _error_api(409, "ARCHIVO_DUPLICADO",
                "Ya existe en este estudio un archivo '$nombre' (no se sobrescribe)")
    catch e
        return _error_interno("Error validando estudio $id_estudio para subida fragmentada", e)
    end

    _limpiar_subidas_vencidas!()

    id_subida = _nuevo_id_subida()
    ruta_tmp = joinpath(_carpeta_tmp_subidas(), "$(id_subida).partial")
    try
        mkpath(_carpeta_tmp_subidas())
        close(open(ruta_tmp, "w"))   # crea el archivo vacío (las partes lo irán llenando)
    catch e
        _borrar_archivos((ruta_tmp,))
        return _error_interno("No se pudo crear el temporal de la subida", e)
    end

    # `cld` = división entera redondeando hacia arriba: 26 MB / 25 MB → 2 partes.
    total_partes = Int(cld(tamano, CHUNK_SIZE_BYTES))
    s = SesionSubida(id_subida, id_estudio, nombre, formato, tipo_archivo, metadatos,
                     tamano, total_partes, ruta_tmp, falses(total_partes),
                     ReentrantLock(), _ahora_utc() + EXPIRACION_SUBIDA, true)
    lock(() -> (_SUBIDAS_ACTIVAS[id_subida] = s), _SUBIDAS_LOCK)

    println("⏫ Subida fragmentada iniciada: '$nombre' ($tamano bytes, $total_partes partes) → estudio $id_estudio")
    return json_response(201, Dict("success" => true, "subida" => _sesion_publica(s)))
end

# =========================================================
# PUT /api/subidas/:id_subida/parte?indice=N
# body: bytes crudos (Content-Type: application/octet-stream)
# =========================================================
function handler_subir_parte(req, params)
    s = _buscar_sesion(params["id_subida"])
    isnothing(s) && return _subida_no_encontrada()

    query, err = _leer_query(req)
    isnothing(err) || return err
    haskey(query, "indice") ||
        return _error_api(400, "PARTE_INVALIDA", "Falta el parámetro '?indice=N'")
    indice, err = _entero_query(query, "indice", 0, 0, s.total_partes - 1)
    isnothing(err) || return _error_api(400, "PARTE_INVALIDA", err)

    # Validaciones de tamaño ANTES de esperar turno en el semáforo.
    datos = _bytes_del_body(req.body)
    recibido = length(datos)
    recibido > CHUNK_SIZE_BYTES && return _error_api(413, "PARTE_INVALIDA",
        "La parte excede el tamaño máximo de $CHUNK_SIZE_BYTES bytes")
    esperado = _tamano_esperado_parte(s, indice)
    recibido == esperado || return _error_api(400, "PARTE_INVALIDA",
        "La parte $indice debe medir exactamente $esperado bytes (llegaron $recibido)")

    Base.acquire(CHUNK_UPLOAD_SEMAPHORE)
    try
        lock(s.lock)
        try
            # Re-chequeo con el lock tomado: pudo completarse/cancelarse mientras esperábamos.
            (s.activa && !_vencida(s)) || return _subida_no_encontrada()
            # "r+" = lectura/escritura SIN truncar. `seek` a la posición de la
            # parte: escribir dos veces la misma parte deja los mismos bytes
            # (idempotente) y el orden de llegada da igual. Se usa `Int64` para
            # que el desplazamiento no se desborde con archivos de varios GB.
            escritos = open(s.ruta_tmp, "r+") do io
                seek(io, Int64(indice) * Int64(CHUNK_SIZE_BYTES))
                write(io, datos)
            end
            escritos == esperado ||
                error("Escritura incompleta de la parte $indice: $escritos de $esperado bytes")
            s.recibidas[indice + 1] = true            # los vectores de Julia empiezan en 1
            s.expira = _ahora_utc() + EXPIRACION_SUBIDA   # renueva el plazo
            return json_response(200, Dict(
                "success"         => true,
                "id_subida"       => s.id_subida,
                "indice"          => indice,
                "partes_recibidas"=> count(s.recibidas),   # cuántos `true` hay
                "total_partes"    => s.total_partes,
                "expira_en"       => _expira_texto(s)
            ))
        finally
            unlock(s.lock)
        end
    catch e
        return _error_interno("Error escribiendo parte de la subida $(s.id_subida)", e)
    finally
        Base.release(CHUNK_UPLOAD_SEMAPHORE)
    end
end

# =========================================================
# POST /api/subidas/:id_subida/completar
# =========================================================
function handler_completar_subida(req, params)
    s = _buscar_sesion(params["id_subida"])
    isnothing(s) && return _subida_no_encontrada()

    lock(s.lock)
    try
        (s.activa && !_vencida(s)) || return _subida_no_encontrada()

        # `findall(!, v)` devuelve las posiciones con `false`; `.- 1` pasa a base 0.
        faltantes = findall(!, s.recibidas) .- 1
        if !isempty(faltantes)
            # NO es terminal: el cliente puede enviar las partes que faltan.
            return _error_api(400, "SUBIDA_INCOMPLETA",
                "Faltan $(length(faltantes)) de $(s.total_partes) partes";
                extra=Dict{String, Any}("partes_faltantes" => first(faltantes, 100),
                                        "partes_recibidas" => count(s.recibidas),
                                        "total_partes"     => s.total_partes))
        end
        return _publicar_subida!(s)
    catch e
        _cerrar_sesion!(s)   # cualquier fallo inesperado aquí es terminal
        return _error_interno("Error completando la subida $(s.id_subida)", e)
    finally
        unlock(s.lock)
    end
end

"""
Publica una subida con todas sus partes (se llama con `s.lock` tomado).
Desde aquí la sesión termina SIEMPRE: con éxito o con error, se quita del
Dict y no queda ningún `.partial`. Mismo patrón que la subida directa:
1. `INSERT` → `UNIQUE(ruta_relativa)` decide si hay colisión (409).
2. `mv` del `.partial` a su nombre final (sin `force`: nunca sobrescribe).
   Si falla, se borra la fila recién insertada (compensación).
"""
function _publicar_subida!(s::SesionSubida)
    s.activa = false
    lock(() -> delete!(_SUBIDAS_ACTIVAS, s.id_subida), _SUBIDAS_LOCK)
    # Función local: borra el temporal y devuelve la respuesta recibida.
    abortar(resp) = (_borrar_archivos((s.ruta_tmp,)); resp)

    tam = filesize(s.ruta_tmp)
    if tam != s.tamano_bytes
        @error "Tamaño del .partial no coincide" id_subida = s.id_subida tam esperado = s.tamano_bytes
        return abortar(_error_api(500, "ERROR_INTERNO", "Error interno del servidor"))
    end

    # El estudio pudo borrarse durante la subida.
    estudio = obtener_estudio_con_paciente(DB_CONN, s.id_estudio)
    isnothing(estudio) && return abortar(_error_api(404, "NO_ENCONTRADO", "Estudio no encontrado"))
    id_paciente = estudio["id_paciente"]::Int

    carpeta = joinpath(PROJECTS_DIR, "_pacientes", "paciente_$(id_paciente)", "estudio_$(s.id_estudio)")
    mkpath(carpeta)   # si falla, el `catch` del handler cierra la sesión y responde 500
    ruta_final = joinpath(carpeta, s.nombre_original)
    registro = (; tipo_archivo    = s.tipo_archivo,
                  formato         = s.formato,
                  nombre_original = s.nombre_original,
                  ruta_relativa   = "_pacientes/paciente_$(id_paciente)/estudio_$(s.id_estudio)/$(s.nombre_original)",
                  tamano_bytes    = s.tamano_bytes,
                  metadatos_extra = s.metadatos)

    archivos = try
        registrar_archivos_medicos(DB_CONN, s.id_estudio, [registro])
    catch e
        es_violacion_unica(e) && return abortar(_error_api(409, "ARCHIVO_DUPLICADO",
            "Ya existe en este estudio un archivo '$(s.nombre_original)' (no se sobrescribe). " *
            "La subida se descartó."))
        es_violacion_fk(e) && return abortar(_error_api(404, "NO_ENCONTRADO", "Estudio no encontrado"))
        rethrow()   # error desconocido: lo maneja el `catch` del handler (500)
    end

    try
        mv(s.ruta_tmp, ruta_final; force=false)   # mismo volumen → renombrado atómico
    catch e
        ids = [a["id_archivo"] for a in archivos]
        try
            eliminar_archivos_medicos(DB_CONN, ids)
        catch e2
            @error "Compensación fallida: fila sin archivo en disco" ids exception = (e2, catch_backtrace())
        end
        if ispath(ruta_final)
            @warn "Existe en disco '$ruta_final' sin registro en la BD (huérfano o colisión de mayúsculas)"
            return abortar(_error_api(409, "ARCHIVO_DUPLICADO",
                "Ya existe en este estudio un archivo '$(s.nombre_original)' (no se sobrescribe). " *
                "La subida se descartó."))
        end
        rethrow()
    end

    println("✅ Subida fragmentada completada: '$(s.nombre_original)' ($(s.tamano_bytes) bytes) → estudio $(s.id_estudio)")
    return json_response(201, Dict("success" => true, "archivo" => first(archivos)))
end

# =========================================================
# DELETE /api/subidas/:id_subida — cancela y borra el `.partial`
# =========================================================
function handler_cancelar_subida(req, params)
    # `incluir_vencidas=true`: una sesión vencida aún no limpiada también se puede cancelar.
    s = _buscar_sesion(params["id_subida"]; incluir_vencidas=true)
    isnothing(s) && return _subida_no_encontrada()

    lock(s.lock)   # espera a que termine una parte que se esté escribiendo
    try
        s.activa || return _subida_no_encontrada()
        _cerrar_sesion!(s)
    finally
        unlock(s.lock)
    end

    println("🚫 Subida fragmentada $(s.id_subida) cancelada")
    return json_response(200, Dict("success" => true, "cancelada" => true,
                                   "id_subida" => s.id_subida))
end

# =========================================================
# CATÁLOGOS Y FILTROS DE ARCHIVOS
# =========================================================

# Formatos válidos derivados de la MISMA tabla que usa la subida (así nunca
# se desincronizan). `last.(v)` aplica `last` a cada par (`".nii" => "NIfTI"`
# → `"NIfTI"`); `unique` conserva el orden de primera aparición.
const FORMATOS_PERMITIDOS = unique(last.(_FORMATOS_POR_EXTENSION))

"""
Valida el filtro opcional `?tipo_archivo=`. Vacío/ausente → sin filtro.
Devuelve `(valor_normalizado_o_nothing, nothing)` o `(nothing, "mensaje")`.
"""
function _filtro_tipo_archivo(texto)
    (isnothing(texto) || isempty(strip(texto))) && return (nothing, nothing)
    tipo = lowercase(strip(texto))
    tipo in TIPOS_ARCHIVO_PERMITIDOS && return (tipo, nothing)
    return (nothing, "'tipo_archivo' inválido. Permitidos: $(join(TIPOS_ARCHIVO_PERMITIDOS, ", "))")
end

"""
Valida el filtro opcional `?formato=` sin distinguir mayúsculas y lo
devuelve con la grafía canónica de la BD (`"nifti"` → `"NIfTI"`).
"""
function _filtro_formato(texto)
    (isnothing(texto) || isempty(strip(texto))) && return (nothing, nothing)
    buscado = lowercase(strip(texto))
    i = findfirst(f -> lowercase(f) == buscado, FORMATOS_PERMITIDOS)
    isnothing(i) &&
        return (nothing, "'formato' inválido. Permitidos: $(join(FORMATOS_PERMITIDOS, ", "))")
    return (FORMATOS_PERMITIDOS[i], nothing)
end

# =========================================================
# GET /api/pacientes/catalogos — valores que el frontend necesita
# =========================================================
function handler_catalogos_pacientes(req, params)
    # Comprensión con filtro: por cada formato, sus extensiones (en el orden
    # de `_FORMATOS_POR_EXTENSION`).
    formatos = [Dict{String, Any}(
                    "formato"     => f,
                    "extensiones" => [ext for (ext, fmt) in _FORMATOS_POR_EXTENSION if fmt == f])
                for f in FORMATOS_PERMITIDOS]

    return json_response(200, Dict(
        "success"       => true,
        "tipos_archivo" => TIPOS_ARCHIVO_PERMITIDOS,
        "formatos"      => formatos,
        "max_upload_mb" => MAX_UPLOAD_BYTES ÷ (1024 * 1024),
        "paginacion"    => Dict("limite_defecto" => LIMITE_PACIENTES_DEFECTO,
                                "limite_maximo"  => LIMITE_PACIENTES_MAXIMO),
        # Para que el frontend decida entre subida directa y fragmentada sin
        # hardcodear constantes.
        "subida_fragmentada" => Dict(
            "tamano_parte_mb"       => CHUNK_SIZE_BYTES ÷ _BYTES_POR_MB,
            "tamano_parte_bytes"    => CHUNK_SIZE_BYTES,
            "max_upload_mb"         => MAX_CHUNKED_UPLOAD_BYTES ÷ _BYTES_POR_MB,
            "umbral_recomendado_mb" => UMBRAL_SUBIDA_FRAGMENTADA_MB)
    ))
end

# =========================================================
# GET /api/estudios/:id — estudio + archivos anidados
# =========================================================
function handler_obtener_estudio(req, params)
    id_estudio = _id_valido(params["id"])
    isnothing(id_estudio) && return _error_api(400, "ID_INVALIDO", "id de estudio inválido")

    try
        estudio = obtener_estudio_con_paciente(DB_CONN, id_estudio)
        isnothing(estudio) && return _error_api(404, "NO_ENCONTRADO", "Estudio no encontrado")
        estudio["archivos"] = listar_archivos_estudio(DB_CONN, id_estudio)
        return json_response(200, Dict("success" => true, "estudio" => estudio))
    catch e
        return _error_interno("Error obteniendo estudio $id_estudio", e)
    end
end

# =========================================================
# GET /api/estudios/:id/archivos?tipo_archivo=...&formato=...
# =========================================================
function handler_listar_archivos_estudio(req, params)
    id_estudio = _id_valido(params["id"])
    isnothing(id_estudio) && return _error_api(400, "ID_INVALIDO", "id de estudio inválido")

    query, err = _leer_query(req)
    isnothing(err) || return err
    tipo_archivo, err = _filtro_tipo_archivo(get(query, "tipo_archivo", nothing))
    isnothing(err) || return _error_api(400, "DATOS_INVALIDOS", err)
    formato, err = _filtro_formato(get(query, "formato", nothing))
    isnothing(err) || return _error_api(400, "DATOS_INVALIDOS", err)

    try
        # Distinguimos "estudio inexistente" (404) de "estudio sin archivos" ([]).
        isnothing(obtener_estudio_con_paciente(DB_CONN, id_estudio)) &&
            return _error_api(404, "NO_ENCONTRADO", "Estudio no encontrado")
        archivos = listar_archivos_estudio(DB_CONN, id_estudio; tipo_archivo, formato)
        return json_response(200, Dict("success" => true,
                                       "id_estudio" => id_estudio,
                                       "archivos" => archivos))
    catch e
        return _error_interno("Error listando archivos del estudio $id_estudio", e)
    end
end

# =========================================================
# GET /api/archivos/:id — metadatos públicos (sin rutas internas)
# =========================================================
function handler_obtener_archivo(req, params)
    id_archivo = _id_valido(params["id"])
    isnothing(id_archivo) && return _error_api(400, "ID_INVALIDO", "id de archivo inválido")

    try
        archivo = obtener_archivo_medico(DB_CONN, id_archivo)
        isnothing(archivo) && return _error_api(404, "NO_ENCONTRADO", "Archivo no encontrado")
        return json_response(200, Dict("success" => true, "archivo" => archivo))
    catch e
        return _error_interno("Error obteniendo archivo $id_archivo", e)
    end
end

# =========================================================
# HELPERS DE DISCO (descarga y borrado)
# =========================================================

"""
Reconstruye la ruta física a partir de `ruta_relativa` (guardada con `/`).
Defensa en profundidad: aunque la BD solo contiene rutas que escribimos
nosotros, se rechaza cualquier segmento vacío, `.`, `..` o con `\\`, y la
ruta debe colgar de `_pacientes/`. Devuelve la ruta o `nothing`.
`joinpath(PROJECTS_DIR, partes...)` usa el separador del sistema operativo;
los `...` ("splat") pasan cada elemento del vector como un argumento.
"""
function _ruta_fisica(ruta_relativa::AbstractString)
    partes = split(ruta_relativa, '/')
    (length(partes) >= 2 && partes[1] == "_pacientes") || return nothing
    any(p -> isempty(p) || p in (".", "..") || occursin('\\', p), partes) && return nothing
    return joinpath(PROJECTS_DIR, partes...)
end

_carpeta_paciente(id_paciente::Integer) =
    joinpath(PROJECTS_DIR, "_pacientes", "paciente_$(id_paciente)")

_carpeta_estudio(id_paciente::Integer, id_estudio::Integer) =
    joinpath(_carpeta_paciente(id_paciente), "estudio_$(id_estudio)")

"""
Borra en disco DESPUÉS de haber borrado en la BD. Si falla (p.ej. un archivo
abierto en Windows) solo se registra con `@error`: el registro ya no existe,
así que la respuesta sigue siendo 200. Devuelve `true` si se pudo limpiar.
`force=true` ignora rutas inexistentes; `recursive=true` borra carpetas.
"""
function _borrar_en_disco(ruta::AbstractString; recursive::Bool=false)
    try
        rm(ruta; recursive=recursive, force=true)
        return true
    catch e
        @error "No se pudo borrar en disco (el registro ya se eliminó de la BD)" ruta exception = (e, catch_backtrace())
        return false
    end
end

"""
`Content-Type` de la descarga según formato/extensión. `.nii.gz` se sirve
como gzip (es lo que es); un `.nii` sin comprimir no tiene tipo MIME
estándar → `application/octet-stream`.
"""
function _content_type_descarga(formato, nombre::AbstractString)
    n = lowercase(nombre)
    endswith(n, ".nii.gz") && return "application/gzip"
    formato == "DICOM" && return "application/dicom"
    formato == "PDF"   && return "application/pdf"
    formato == "PNG"   && return "image/png"
    formato == "CSV"   && return "text/csv; charset=utf-8"
    formato == "ZIP"   && return "application/zip"
    endswith(n, ".xlsx") && return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    endswith(n, ".xls")  && return "application/vnd.ms-excel"
    return "application/octet-stream"
end

"""
Header `Content-Disposition` seguro. `filename="..."` lleva una versión
ASCII saneada (sin comillas, `\\` ni caracteres de control/no ASCII, que se
cambian por `_`); `filename*=UTF-8''...` (RFC 6266/5987) lleva el nombre
real codificado con `%XX` para los navegadores modernos.
"""
function _content_disposition(nombre::AbstractString)
    # `map` sobre un String aplica la función a cada carácter y devuelve un String.
    nombre_ascii = map(c -> (isascii(c) && !iscntrl(c) && c != '"' && c != '\\') ? c : '_', nombre)
    return "attachment; filename=\"$nombre_ascii\"; filename*=UTF-8''$(HTTP.URIs.escapeuri(nombre))"
end

# =========================================================
# GET /api/archivos/:id/descarga — bytes del archivo
# =========================================================
function handler_descargar_archivo(req, params)
    id_archivo = _id_valido(params["id"])
    isnothing(id_archivo) && return _error_api(400, "ID_INVALIDO", "id de archivo inválido")

    archivo = try
        obtener_archivo_medico_interno(DB_CONN, id_archivo)
    catch e
        return _error_interno("Error consultando archivo $id_archivo para descarga", e)
    end
    isnothing(archivo) && return _error_api(404, "NO_ENCONTRADO", "Archivo no encontrado")

    ruta = _ruta_fisica(archivo.ruta_relativa)
    if isnothing(ruta)
        @error "ruta_relativa inesperada en la BD" id_archivo ruta_relativa = archivo.ruta_relativa
        return _error_api(500, "ERROR_INTERNO", "Error interno del servidor")
    end

    no_disponible() = _error_api(404, "ARCHIVO_NO_DISPONIBLE",
        "El archivo está registrado pero no se encuentra en el servidor")
    if !isfile(ruta)
        @warn "Archivo registrado en BD pero ausente en disco" id_archivo ruta
        return no_disponible()
    end

    # Tamaño REAL en disco (no el de la BD) para calcular rangos.
    total = Int64(filesize(ruta))

    # --- Header `Range` opcional → 206 Partial Content ---
    texto_rango = HTTP.header(req, "Range", "")
    rango = nothing
    if !isempty(texto_rango)
        rango = _parsear_rango(texto_rango, total)
        if isnothing(rango)
            resp = _error_api(416, "RANGO_INVALIDO",
                "Rango no válido. Usa un único rango 'bytes=inicio-fin', 'bytes=inicio-' " *
                "o 'bytes=-N' dentro de 0..$(total - 1)")
            HTTP.setheader(resp, "Content-Range" => "bytes */$total")   # RFC 9110: tamaño total
            HTTP.setheader(resp, "Access-Control-Expose-Headers" => "Content-Range")
            return resp
        end
    end
    # Desestructuración de tupla: sin Range se lee el archivo entero.
    inicio, fin = isnothing(rango) ? (Int64(0), total - 1) : rango
    n = fin - inicio + 1

    # El router no soporta streaming: el bloque pedido se carga en RAM. Si es
    # grande (>= 100 MiB), solo se permite UNA lectura así a la vez; las demás
    # esperan turno. `grande && f()` ejecuta `f()` solo si `grande` es true.
    grande = n >= UMBRAL_DESCARGA_GRANDE_BYTES
    grande && Base.acquire(LARGE_DOWNLOAD_SEMAPHORE)
    bytes = try
        _leer_bloque(ruta, inicio, n)
    catch e
        isfile(ruta) || return no_disponible()   # se borró justo entre el chequeo y la lectura
        return _error_interno("Error leyendo $ruta", e)
    finally
        grande && Base.release(LARGE_DOWNLOAD_SEMAPHORE)
    end

    resp = HTTP.Response(isnothing(rango) ? 200 : 206, bytes)
    # Primero CORS (que fija `Content-Type: application/json`) y DESPUÉS lo
    # sobrescribimos: `setheader` reemplaza un header existente.
    HttpUtils.add_cors_headers(resp)
    HTTP.setheader(resp, "Content-Type" => _content_type_descarga(archivo.formato, archivo.nombre_original))
    HTTP.setheader(resp, "Content-Disposition" => _content_disposition(archivo.nombre_original))
    HTTP.setheader(resp, "Content-Length" => string(length(bytes)))
    HTTP.setheader(resp, "Accept-Ranges" => "bytes")              # anuncia soporte de rangos
    isnothing(rango) || HTTP.setheader(resp, "Content-Range" => "bytes $inicio-$fin/$total")
    HTTP.setheader(resp, "Cache-Control" => "no-store")            # datos médicos: no cachear
    HTTP.setheader(resp, "X-Content-Type-Options" => "nosniff")    # el navegador no "adivina" el tipo
    # Sin esto, `fetch` desde otro origen no podría leer estos headers.
    HTTP.setheader(resp, "Access-Control-Expose-Headers" =>
                   "Content-Disposition, Content-Length, Content-Range, Accept-Ranges")
    return resp
end

# Un único rango: `bytes=inicio-fin`, `bytes=inicio-` o `bytes=-N`.
# `{0,19}` limita los dígitos (Int64 tiene 19) y `[0-9]` evita dígitos Unicode.
const _REGEX_RANGE = r"^bytes=([0-9]{0,19})-([0-9]{0,19})$"

"""
Interpreta el header `Range` para un archivo de `total` bytes. Devuelve
`(inicio, fin)` (base 0, ambos inclusivos, como en HTTP) o `nothing` si es
inválido o no se puede satisfacer (→ 416). Varios rangos (`bytes=0-1,5-9`)
no se admiten. Un `fin` mayor que el archivo se recorta al último byte
(lo permite el estándar). `m.captures` son los textos de los grupos `(...)`.
"""
function _parsear_rango(texto::AbstractString, total::Int64)
    m = match(_REGEX_RANGE, strip(texto))
    (isnothing(m) || total <= 0) && return nothing
    txt_inicio, txt_fin = m.captures
    if isempty(txt_inicio)                       # "bytes=-N": últimos N bytes
        n = isempty(txt_fin) ? nothing : tryparse(Int64, txt_fin)
        (isnothing(n) || n == 0) && return nothing
        return (max(total - n, Int64(0)), total - 1)
    end
    inicio = tryparse(Int64, txt_inicio)
    (isnothing(inicio) || inicio >= total) && return nothing
    fin = isempty(txt_fin) ? total - 1 : tryparse(Int64, txt_fin)
    (isnothing(fin) || fin < inicio) && return nothing
    return (inicio, min(fin, total - 1))
end

"""
Lee exactamente `n` bytes desde la posición `inicio` sin cargar el resto del
archivo: `seek` mueve el cursor y `read(io, n)` lee como máximo `n` bytes.
"""
function _leer_bloque(ruta::AbstractString, inicio::Int64, n::Int64)
    return open(ruta, "r") do io
        seek(io, inicio)
        bytes = read(io, n)
        length(bytes) == n || error("Lectura incompleta de $ruta: $(length(bytes)) de $n bytes")
        bytes
    end
end

# =========================================================
# EDICIÓN PARCIAL (PUT)
# =========================================================
#
# Regla común: campo OMITIDO → no se toca; campo con `null` → se limpia
# (si la columna lo admite). Se valida todo ANTES de tocar la BD y se arma
# un `Vector{Pair}` con los cambios que `PacientesQueries` convierte en un
# único `UPDATE ... RETURNING`.

_sin_campos_editables(campos) = _error_api(400, "DATOS_INVALIDOS",
    "No se envió ningún campo editable. Campos permitidos: $(join(campos, ", "))")

# PUT /api/pacientes/:id   body: {codigo_paciente?, nombre?, datos_clinicos?, notas?}
function handler_actualizar_paciente(req, params)
    id_paciente = _id_valido(params["id"])
    isnothing(id_paciente) && return _error_api(400, "ID_INVALIDO", "id de paciente inválido")

    body, err = _leer_objeto_json(req)
    isnothing(err) || return err

    cambios = Pair{String, Any}[]

    if _campo_presente(body, "codigo_paciente")
        codigo = get(body, "codigo_paciente", nothing)
        # Es obligatorio en la BD: `null` o texto inválido → 400.
        (codigo isa AbstractString && _codigo_paciente_valido(String(codigo))) ||
            return _error_api(400, "DATOS_INVALIDOS", _MENSAJE_CODIGO_INVALIDO)
        push!(cambios, "codigo_paciente" => String(codigo))
    end

    if _campo_presente(body, "nombre")
        nombre, err = _texto_opcional(body, "nombre")   # null o "" → nothing (limpiar)
        isnothing(err) || return _error_api(400, "DATOS_INVALIDOS", err)
        push!(cambios, "nombre" => nombre)
    end

    if _campo_presente(body, "notas")
        notas, err = _texto_opcional(body, "notas"; max_largo=10_000)
        isnothing(err) || return _error_api(400, "DATOS_INVALIDOS", err)
        push!(cambios, "notas" => notas)
    end

    if _campo_presente(body, "datos_clinicos")
        datos = get(body, "datos_clinicos", nothing)
        (isnothing(datos) || datos isa JSON3.Object) ||
            return _error_api(400, "DATOS_INVALIDOS", "'datos_clinicos' debe ser un objeto JSON o null")
        push!(cambios, "datos_clinicos" => datos)
    end

    isempty(cambios) &&
        return _sin_campos_editables(("codigo_paciente", "nombre", "datos_clinicos", "notas"))

    try
        paciente = actualizar_paciente(DB_CONN, id_paciente, cambios)
        isnothing(paciente) && return _error_api(404, "NO_ENCONTRADO", "Paciente no encontrado")
        println("✏️ Paciente $id_paciente actualizado")
        return json_response(200, Dict("success" => true, "paciente" => paciente))
    catch e
        es_violacion_unica(e) && return _error_api(409, "PACIENTE_DUPLICADO",
            "Ya existe otro paciente con ese codigo_paciente " *
            "(no se distinguen mayúsculas/minúsculas)")
        return _error_interno("Error actualizando paciente $id_paciente", e)
    end
end

# PUT /api/estudios/:id   body: {modalidad?, fecha_estudio?, descripcion?}
function handler_actualizar_estudio(req, params)
    id_estudio = _id_valido(params["id"])
    isnothing(id_estudio) && return _error_api(400, "ID_INVALIDO", "id de estudio inválido")

    body, err = _leer_objeto_json(req)
    isnothing(err) || return err

    cambios = Pair{String, Any}[]

    if _campo_presente(body, "modalidad")
        modalidad, err = _texto_opcional(body, "modalidad")
        isnothing(err) || return _error_api(400, "DATOS_INVALIDOS", err)
        push!(cambios, "modalidad" => (isnothing(modalidad) ? nothing : uppercase(modalidad)))
    end

    if _campo_presente(body, "descripcion")
        descripcion, err = _texto_opcional(body, "descripcion"; max_largo=10_000)
        isnothing(err) || return _error_api(400, "DATOS_INVALIDOS", err)
        push!(cambios, "descripcion" => descripcion)
    end

    if _campo_presente(body, "fecha_estudio")
        fecha_texto, err = _texto_opcional(body, "fecha_estudio")
        isnothing(err) || return _error_api(400, "DATOS_INVALIDOS", err)
        fecha_estudio = nothing   # null → limpiar la fecha
        if !isnothing(fecha_texto)
            dt = _parsear_fecha_iso(fecha_texto)   # acepta el formato de JS con `Z`
            isnothing(dt) && return _error_api(400, "DATOS_INVALIDOS",
                "'fecha_estudio' debe ser ISO-8601: 'AAAA-MM-DD', 'AAAA-MM-DDTHH:MM:SS' " *
                "o 'AAAA-MM-DDTHH:MM:SS.sssZ' (UTC)")
            fecha_estudio = string(dt)
        end
        push!(cambios, "fecha_estudio" => fecha_estudio)
    end

    isempty(cambios) &&
        return _sin_campos_editables(("modalidad", "fecha_estudio", "descripcion"))

    try
        estudio = actualizar_estudio(DB_CONN, id_estudio, cambios)
        isnothing(estudio) && return _error_api(404, "NO_ENCONTRADO", "Estudio no encontrado")
        println("✏️ Estudio $id_estudio actualizado")
        return json_response(200, Dict("success" => true, "estudio" => estudio))
    catch e
        return _error_interno("Error actualizando estudio $id_estudio", e)
    end
end

# PUT /api/archivos/:id   body: {tipo_archivo?, metadatos_extra?}
# No renombra ni mueve el archivo físico.
function handler_actualizar_archivo(req, params)
    id_archivo = _id_valido(params["id"])
    isnothing(id_archivo) && return _error_api(400, "ID_INVALIDO", "id de archivo inválido")

    body, err = _leer_objeto_json(req)
    isnothing(err) || return err

    cambios = Pair{String, Any}[]

    if _campo_presente(body, "tipo_archivo")
        tipo = get(body, "tipo_archivo", nothing)
        # Columna obligatoria: `null` no se admite.
        tipo_ok = tipo isa AbstractString ? lowercase(strip(tipo)) : nothing
        (!isnothing(tipo_ok) && tipo_ok in TIPOS_ARCHIVO_PERMITIDOS) ||
            return _error_api(400, "DATOS_INVALIDOS",
                "'tipo_archivo' inválido. Permitidos: $(join(TIPOS_ARCHIVO_PERMITIDOS, ", "))")
        push!(cambios, "tipo_archivo" => String(tipo_ok))
    end

    if _campo_presente(body, "metadatos_extra")
        metadatos = get(body, "metadatos_extra", nothing)
        (isnothing(metadatos) || metadatos isa AbstractDict) ||
            return _error_api(400, "DATOS_INVALIDOS", "'metadatos_extra' debe ser un objeto JSON o null")
        push!(cambios, "metadatos_extra" => metadatos)
    end

    isempty(cambios) && return _sin_campos_editables(("tipo_archivo", "metadatos_extra"))

    try
        archivo = actualizar_archivo_medico(DB_CONN, id_archivo, cambios)
        isnothing(archivo) && return _error_api(404, "NO_ENCONTRADO", "Archivo no encontrado")
        println("✏️ Archivo $id_archivo actualizado")
        return json_response(200, Dict("success" => true, "archivo" => archivo))
    catch e
        return _error_interno("Error actualizando archivo $id_archivo", e)
    end
end

# =========================================================
# BORRADO (DELETE): primero BD (atómico), luego disco (best effort)
# =========================================================
#
# ¿Por qué en ese orden? Si borráramos primero el disco y luego fallara la
# BD, quedarían filas apuntando a archivos inexistentes. Al revés, lo peor
# que puede pasar es un archivo huérfano en disco (se registra con @error).
# `DELETE ... RETURNING` borra y nos dice qué borró en una sola sentencia:
# no hace falta un SELECT previo (sin carrera entre "comprobar" y "borrar").

# DELETE /api/archivos/:id
function handler_eliminar_archivo(req, params)
    id_archivo = _id_valido(params["id"])
    isnothing(id_archivo) && return _error_api(400, "ID_INVALIDO", "id de archivo inválido")

    borrado = try
        eliminar_archivo_medico(DB_CONN, id_archivo)
    catch e
        return _error_interno("Error eliminando archivo $id_archivo", e)
    end
    isnothing(borrado) && return _error_api(404, "NO_ENCONTRADO", "Archivo no encontrado")

    ruta = _ruta_fisica(borrado.ruta_relativa)
    limpio = if isnothing(ruta)
        @error "ruta_relativa inesperada; no se borra nada en disco" id_archivo ruta_relativa = borrado.ruta_relativa
        false
    else
        _borrar_en_disco(ruta)
    end

    println("🗑️ Archivo $id_archivo eliminado")
    return json_response(200, Dict("success" => true, "eliminado" => true,
                                   "id_archivo" => id_archivo,
                                   "limpieza_disco" => limpio))
end

# DELETE /api/estudios/:id   (la cascada borra sus archivos_medicos)
function handler_eliminar_estudio(req, params)
    id_estudio = _id_valido(params["id"])
    isnothing(id_estudio) && return _error_api(400, "ID_INVALIDO", "id de estudio inválido")

    borrado = try
        eliminar_estudio(DB_CONN, id_estudio)
    catch e
        return _error_interno("Error eliminando estudio $id_estudio", e)
    end
    isnothing(borrado) && return _error_api(404, "NO_ENCONTRADO", "Estudio no encontrado")

    limpio = _borrar_en_disco(_carpeta_estudio(borrado.id_paciente, borrado.id_estudio);
                              recursive=true)

    println("🗑️ Estudio $id_estudio eliminado (paciente $(borrado.id_paciente))")
    return json_response(200, Dict("success" => true, "eliminado" => true,
                                   "id_estudio" => id_estudio,
                                   "id_paciente" => borrado.id_paciente,
                                   "limpieza_disco" => limpio))
end

# DELETE /api/pacientes/:id   (la cascada borra estudios y archivos)
function handler_eliminar_paciente(req, params)
    id_paciente = _id_valido(params["id"])
    isnothing(id_paciente) && return _error_api(400, "ID_INVALIDO", "id de paciente inválido")

    borrado = try
        eliminar_paciente(DB_CONN, id_paciente)
    catch e
        return _error_interno("Error eliminando paciente $id_paciente", e)
    end
    isnothing(borrado) && return _error_api(404, "NO_ENCONTRADO", "Paciente no encontrado")

    limpio = _borrar_en_disco(_carpeta_paciente(id_paciente); recursive=true)

    println("🗑️ Paciente $id_paciente eliminado")
    return json_response(200, Dict("success" => true, "eliminado" => true,
                                   "id_paciente" => id_paciente,
                                   "limpieza_disco" => limpio))
end

# =========================================================
# REGISTRO DE RUTAS
# =========================================================
# El router devuelve la PRIMERA ruta que coincide. Por eso las rutas
# estáticas o más específicas (`/catalogos`, `/codigo/:codigo`) se registran
# ANTES que `/api/pacientes/:id`: si no, "catalogos" se capturaría como `:id`.

# --- Pacientes ---
registrar_ruta!("GET",    "/api/pacientes/catalogos",       handler_catalogos_pacientes)
registrar_ruta!("GET",    "/api/pacientes/codigo/:codigo",  handler_obtener_paciente_por_codigo)
registrar_ruta!("GET",    "/api/pacientes",                 handler_listar_pacientes)
registrar_ruta!("POST",   "/api/pacientes",                 handler_crear_paciente)
registrar_ruta!("GET",    "/api/pacientes/:id",             handler_obtener_paciente)
registrar_ruta!("PUT",    "/api/pacientes/:id",             handler_actualizar_paciente)
registrar_ruta!("DELETE", "/api/pacientes/:id",             handler_eliminar_paciente)
registrar_ruta!("POST",   "/api/pacientes/:id/estudios",    handler_crear_estudio)

# --- Estudios ---
registrar_ruta!("GET",    "/api/estudios/:id",              handler_obtener_estudio)
registrar_ruta!("PUT",    "/api/estudios/:id",              handler_actualizar_estudio)
registrar_ruta!("DELETE", "/api/estudios/:id",              handler_eliminar_estudio)
registrar_ruta!("GET",    "/api/estudios/:id/archivos",     handler_listar_archivos_estudio)
registrar_ruta!("POST",   "/api/estudios/:id/archivos",     handler_subir_archivos_estudio)
registrar_ruta!("POST",   "/api/estudios/:id/subidas",      handler_iniciar_subida)

# --- Subidas fragmentadas (archivos grandes) ---
registrar_ruta!("PUT",    "/api/subidas/:id_subida/parte",     handler_subir_parte)
registrar_ruta!("POST",   "/api/subidas/:id_subida/completar", handler_completar_subida)
registrar_ruta!("DELETE", "/api/subidas/:id_subida",           handler_cancelar_subida)

# --- Archivos médicos ---
registrar_ruta!("GET",    "/api/archivos/:id/descarga",     handler_descargar_archivo)
registrar_ruta!("GET",    "/api/archivos/:id",              handler_obtener_archivo)
registrar_ruta!("PUT",    "/api/archivos/:id",              handler_actualizar_archivo)
registrar_ruta!("DELETE", "/api/archivos/:id",              handler_eliminar_archivo)
