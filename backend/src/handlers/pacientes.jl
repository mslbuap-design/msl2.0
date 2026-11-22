# ==============================================================================
# Handlers del repositorio histórico de pacientes
# (Bloque 2: CRUD básico · Bloque 3: subida de archivos médicos)
# ==============================================================================
#
# Jerarquía: Paciente -> Estudio -> Archivo médico (ver SPEC.md).
# Las consultas viven en `PacientesQueries` (database/pacientes_queries.jl);
# aquí solo validamos la entrada HTTP y armamos la respuesta JSON.
#
# Este archivo se incluye desde server.jl en el ámbito `Main`, así que ya
# tiene disponibles `DB_CONN`, `json_response`, `error_response`,
# `leer_body_json`, `parse_int_seguro`, `registrar_ruta!`, `HTTP`, `JSON3`,
# `Dates` y `PROJECTS_DIR`.
# ==============================================================================

# =========================================================
# HELPERS DE VALIDACIÓN
# =========================================================

# Regex del código de paciente: empieza con letra/dígito y después solo
# letras, dígitos, `.`, `_` o `-` (máximo 64 caracteres en total). Como no
# admite `/`, `\`, espacios ni un `.` inicial, el código siempre es un nombre
# de carpeta seguro (no puede ser `..` ni escaparse de `_pacientes/`).
# `r"..."` es la sintaxis de Julia para un literal de expresión regular.
const _REGEX_CODIGO_PACIENTE = r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"

"""
Devuelve `true` si `codigo` es un código de paciente válido y seguro como
nombre de carpeta (ver `_REGEX_CODIGO_PACIENTE`).
"""
_codigo_paciente_valido(codigo::AbstractString) =
    occursin(_REGEX_CODIGO_PACIENTE, codigo) && !occursin("..", codigo)

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

"""
Valida una fecha ISO (`"2026-11-21"` o `"2026-11-21T10:30:00"`) y la
normaliza como `DateTime`. Devuelve `nothing` si el texto no es una fecha
válida. `tryparse` es como `parse` pero devuelve `nothing` en vez de lanzar
un error.
"""
function _parsear_fecha_iso(texto::AbstractString)
    dt = tryparse(Dates.DateTime, texto)
    !isnothing(dt) && return dt
    d = tryparse(Dates.Date, texto)
    return isnothing(d) ? nothing : Dates.DateTime(d)
end

"""
Detecta si una excepción de LibPQ es una violación de UNIQUE (SQLSTATE
23505). Comparamos el nombre del tipo (`LibPQ.Errors.UniqueViolation`) en
vez de usar `isa` para no tener que cargar `LibPQ` en `Main`. Si el tipo no
viene, se revisa el texto del error como respaldo.
"""
function _es_violacion_unicidad(e)
    nameof(typeof(e)) == :UniqueViolation && return true
    mensaje = sprint(showerror, e)
    return occursin("23505", mensaje) || occursin("duplicate key", mensaje)
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
        return (nothing, error_response(400, "El body no es JSON válido"))
    end
    body isa JSON3.Object ||
        return (nothing, error_response(400, "El body debe ser un objeto JSON"))
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
        return error_response(400, "'codigo_paciente' es obligatorio")
    end
    codigo = String(codigo)
    if !_codigo_paciente_valido(codigo)
        return error_response(400,
            "'codigo_paciente' inválido: usa solo letras, números, '.', '_' o '-' " *
            "(sin espacios ni '/', '\\', '..'; máx. 64 caracteres)")
    end

    # --- opcionales de texto ---
    nombre, err = _texto_opcional(body, "nombre")
    isnothing(err) || return error_response(400, err)
    notas, err = _texto_opcional(body, "notas"; max_largo=10_000)
    isnothing(err) || return error_response(400, err)

    # --- datos_clinicos: debe ser un objeto JSON (o ausente/null) ---
    datos_clinicos = get(body, "datos_clinicos", nothing)
    if !isnothing(datos_clinicos) && !(datos_clinicos isa JSON3.Object)
        return error_response(400, "'datos_clinicos' debe ser un objeto JSON")
    end

    try
        id_paciente = crear_paciente(DB_CONN, codigo;
                                     nombre=nombre,
                                     datos_clinicos=datos_clinicos,
                                     notas=notas)
        paciente = obtener_paciente(DB_CONN, id_paciente)
        println("🧑‍⚕️ Paciente creado: $codigo (id $id_paciente)")
        return json_response(201, Dict("success" => true, "paciente" => paciente))
    catch e
        # Sin pre-chequear con SELECT: dejamos que la restricción UNIQUE de
        # PostgreSQL decida (evita la carrera entre dos requests simultáneos).
        if _es_violacion_unicidad(e)
            return error_response(409, "Ya existe un paciente con codigo_paciente '$codigo'")
        end
        println("❌ Error creando paciente: ", e)
        return error_response(500, string(e))
    end
end

# =========================================================
# GET /api/pacientes?buscar=...   (alias aceptado: ?q=..., ver SPEC.md)
# =========================================================
function handler_listar_pacientes(req, params)
    # `queryparams` convierte "?buscar=PAC&x=1" en Dict("buscar"=>"PAC","x"=>"1").
    query = HTTP.URIs.queryparams(HTTP.URI(req.target))
    busqueda = get(query, "buscar", get(query, "q", nothing))

    try
        pacientes = listar_pacientes(DB_CONN; busqueda=busqueda)
        return json_response(200, Dict("success" => true, "pacientes" => pacientes))
    catch e
        println("❌ Error listando pacientes: ", e)
        return error_response(500, string(e))
    end
end

# =========================================================
# POST /api/pacientes/:id/estudios
# body: {modalidad?, fecha_estudio? (ISO), descripcion?}
# =========================================================
function handler_crear_estudio(req, params)
    id_paciente = parse_int_seguro(params["id"])
    isnothing(id_paciente) && return error_response(400, "id de paciente inválido")

    body, err = _leer_objeto_json(req)
    isnothing(err) || return err

    modalidad, err = _texto_opcional(body, "modalidad")
    isnothing(err) || return error_response(400, err)
    # Normalizamos a mayúsculas ("mri" -> "MRI") para que los filtros futuros
    # no dependan de cómo lo escribió cada usuario.
    modalidad = isnothing(modalidad) ? nothing : uppercase(modalidad)

    descripcion, err = _texto_opcional(body, "descripcion"; max_largo=10_000)
    isnothing(err) || return error_response(400, err)

    fecha_texto, err = _texto_opcional(body, "fecha_estudio")
    isnothing(err) || return error_response(400, err)
    fecha_estudio = nothing
    if !isnothing(fecha_texto)
        dt = _parsear_fecha_iso(fecha_texto)
        isnothing(dt) && return error_response(400,
            "'fecha_estudio' debe ser ISO: 'AAAA-MM-DD' o 'AAAA-MM-DDTHH:MM:SS'")
        fecha_estudio = string(dt)   # texto ISO normalizado para `::timestamp`
    end

    try
        isnothing(obtener_paciente(DB_CONN, id_paciente)) &&
            return error_response(404, "Paciente no encontrado")

        id_estudio = crear_estudio(DB_CONN, id_paciente;
                                   modalidad=modalidad,
                                   fecha_estudio=fecha_estudio,
                                   descripcion=descripcion)
        estudio = obtener_estudio_con_codigo(DB_CONN, id_estudio)
        println("📋 Estudio $id_estudio creado para paciente $id_paciente")
        return json_response(201, Dict("success" => true, "estudio" => estudio))
    catch e
        println("❌ Error creando estudio: ", e)
        return error_response(500, string(e))
    end
end

# =========================================================
# GET /api/pacientes/:id — paciente + estudios + archivos anidados
# =========================================================
function handler_obtener_paciente(req, params)
    id_paciente = parse_int_seguro(params["id"])
    isnothing(id_paciente) && return error_response(400, "id de paciente inválido")

    try
        paciente = obtener_paciente(DB_CONN, id_paciente)
        isnothing(paciente) && return error_response(404, "Paciente no encontrado")

        # Ya vienen ordenados (más reciente primero) desde la query.
        estudios = listar_estudios_paciente(DB_CONN, id_paciente)

        # Una sola consulta para todos los archivos; luego los agrupamos en
        # memoria por id_estudio. `get!(f, dict, clave)` devuelve el vector
        # de esa clave, creándolo con `f()` si todavía no existe.
        archivos_por_estudio = Dict{Int, Vector{Dict{String, Any}}}()
        for archivo in listar_archivos_paciente(DB_CONN, id_paciente)
            lista = get!(() -> Dict{String, Any}[], archivos_por_estudio,
                         Int(archivo["id_estudio"]))
            push!(lista, archivo)
        end

        for estudio in estudios
            estudio["archivos"] = get(archivos_por_estudio,
                                      Int(estudio["id_estudio"]),
                                      Dict{String, Any}[])
        end

        paciente["estudios"] = estudios
        return json_response(200, Dict("success" => true, "paciente" => paciente))
    catch e
        println("❌ Error obteniendo paciente: ", e)
        return error_response(500, string(e))
    end
end

# =========================================================
# BLOQUE 3: SUBIDA DE ARCHIVOS MÉDICOS
# =========================================================

# Límite total del body (todas las partes juntas). Es una `const` global:
# Julia conoce su tipo en tiempo de compilación, así que leerla es gratis.
# Para cambiar el límite basta con editar esta línea.
const MAX_UPLOAD_BYTES = 500 * 1024 * 1024   # 500 MB

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
    ".xlsx"   => "Excel",
    ".xls"    => "Excel",
    ".csv"    => "CSV",
    ".png"    => "PNG",
    ".pdf"    => "PDF",
]

# Nombres de campo del formulario que se consideran archivos (`files` pensando
# en series DICOM con muchas partes).
const _CAMPOS_ARCHIVO = ("file", "files")

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
Sanea el nombre que envía el cliente. Devuelve `(nombre, nothing)` o
`(nothing, "mensaje")`. `basename` se queda con la última parte de una ruta;
si el resultado difiere del original, el cliente mandó separadores (`a/b.nii`)
y lo rechazamos en vez de "arreglarlo" en silencio. También se rechazan `..`,
caracteres de control y los reservados de Windows (por si se prueba en local).
"""
function _sanear_nombre_archivo(nombre_crudo::AbstractString)
    nombre = String(strip(nombre_crudo))
    isempty(nombre) && return (nothing, "Hay un archivo sin nombre")
    if occursin('/', nombre) || occursin('\\', nombre) || basename(nombre) != nombre
        return (nothing, "Nombre de archivo inválido (contiene separadores de ruta): '$nombre'")
    end
    if nombre in (".", "..") || occursin("..", nombre)
        return (nothing, "Nombre de archivo inválido (contiene '..'): '$nombre'")
    end
    # `any(f, texto)` recorre cada carácter; `iscntrl` detecta \0, \n, etc.
    if any(c -> iscntrl(c) || c in "<>:\"|?*", nombre)
        return (nothing, "Nombre de archivo con caracteres no permitidos: '$nombre'")
    end
    ncodeunits(nombre) > 255 && return (nothing, "Nombre de archivo demasiado largo: '$nombre'")
    return (nombre, nothing)
end

"Lee todo el contenido de una parte multipart como bytes (`Vector{UInt8}`)."
_bytes_de_parte(parte) = read(seekstart(parte.data))

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

# =========================================================
# POST /api/estudios/:id/archivos   (multipart/form-data)
# partes: file|files (1..N archivos), tipo_archivo?, metadatos? (JSON)
# =========================================================
function handler_subir_archivos_estudio(req, params)
    # ---------- FASE 1: validar todo, sin tocar el disco ----------

    _excede_limite_subida(req) && return error_response(413,
        "La subida excede el límite de $(MAX_UPLOAD_BYTES ÷ (1024 * 1024)) MB")

    id_estudio = parse_int_seguro(params["id"])
    isnothing(id_estudio) && return error_response(400, "id de estudio inválido")

    estudio = try
        obtener_estudio_con_codigo(DB_CONN, id_estudio)
    catch e
        println("❌ Error consultando estudio $id_estudio: ", e)
        return error_response(500, string(e))
    end
    isnothing(estudio) && return error_response(404, "Estudio no encontrado")

    # El código ya se validó al crear el paciente; lo revisamos otra vez
    # porque con él se construye una ruta en disco (defensa en profundidad).
    codigo_paciente = String(estudio["codigo_paciente"])
    _codigo_paciente_valido(codigo_paciente) || return error_response(500,
        "El codigo_paciente guardado no es seguro como nombre de carpeta")

    # `parse_multipart_form` devuelve `nothing` si el Content-Type no es
    # multipart/form-data; puede lanzar error si el body está corrupto.
    partes = try
        HTTP.parse_multipart_form(req)
    catch
        nothing
    end
    isnothing(partes) && return error_response(400,
        "El body debe ser multipart/form-data válido")

    # Separamos partes de archivo (tienen `filename`) y campos de texto.
    partes_archivo = [p for p in partes if p.name in _CAMPOS_ARCHIVO && !isnothing(p.filename)]
    isempty(partes_archivo) && return error_response(400,
        "No se recibió ningún archivo (usa el campo 'file' o 'files')")

    campos_texto = Dict{String, String}()
    for p in partes
        if isnothing(p.filename) && !haskey(campos_texto, p.name)
            campos_texto[p.name] = String(strip(String(_bytes_de_parte(p))))
        end
    end

    # --- tipo_archivo (opcional, por defecto "imagen") ---
    tipo_archivo = get(campos_texto, "tipo_archivo", "")
    tipo_archivo = isempty(tipo_archivo) ? "imagen" : lowercase(tipo_archivo)
    tipo_archivo in TIPOS_ARCHIVO_PERMITIDOS || return error_response(400,
        "'tipo_archivo' inválido. Permitidos: $(join(TIPOS_ARCHIVO_PERMITIDOS, ", "))")

    # --- metadatos (opcional, texto JSON que debe ser un objeto) ---
    metadatos = nothing
    texto_metadatos = get(campos_texto, "metadatos", "")
    if !isempty(texto_metadatos)
        metadatos = try
            JSON3.read(texto_metadatos)
        catch
            return error_response(400, "'metadatos' no es JSON válido")
        end
        metadatos isa AbstractDict ||
            return error_response(400, "'metadatos' debe ser un objeto JSON ({...})")
    end

    carpeta = abspath(joinpath(PROJECTS_DIR, "_pacientes", codigo_paciente,
                               "estudio_$(id_estudio)"))

    # Validamos cada archivo y acumulamos lo necesario para la fase 2.
    # `NamedTuple` (`(; a=1, b=2)`) es un registro inmutable y liviano.
    pendientes = NamedTuple[]
    vistos = Set{String}()   # nombres ya usados en ESTA petición (en minúsculas)
    for parte in partes_archivo
        nombre, err = _sanear_nombre_archivo(parte.filename)
        isnothing(err) || return error_response(400, err)

        formato = _detectar_formato(nombre)
        isnothing(formato) && return error_response(400,
            "Extensión no permitida en '$nombre'. Usa: " *
            join(first.(_FORMATOS_POR_EXTENSION), ", "))

        # Comparamos en minúsculas: en Windows/macOS `A.nii` y `a.nii` son el
        # mismo archivo en disco.
        clave = lowercase(nombre)
        clave in vistos && return error_response(409,
            "El archivo '$nombre' viene repetido en la petición")
        push!(vistos, clave)

        ruta = joinpath(carpeta, nombre)
        ispath(ruta) && return error_response(409,
            "Ya existe un archivo '$nombre' en este estudio (no se sobrescribe)")

        datos = _bytes_de_parte(parte)
        isempty(datos) && return error_response(400, "El archivo '$nombre' está vacío")

        push!(pendientes, (; nombre, formato, ruta, datos))
    end

    # ---------- FASE 2: escribir en disco + INSERT (con compensación) ----------
    #
    # No usamos BEGIN/COMMIT porque `DB_CONN` es una única conexión compartida
    # entre threads: una transacción abierta aquí mezclaría consultas de otros
    # requests. En su lugar: escribir archivo -> INSERT -> si falla, borrar.
    ids_creados = Int[]
    nombres_creados = String[]
    try
        mkpath(carpeta)   # crea toda la cadena de carpetas si no existe
    catch e
        println("❌ No se pudo crear la carpeta $carpeta: ", e)
        return error_response(500, "No se pudo crear la carpeta del estudio")
    end

    for p in pendientes
        # Re-chequeo justo antes de escribir: otro request simultáneo pudo
        # haber creado el mismo archivo después de la fase 1.
        if ispath(p.ruta)
            return error_response(409, "El archivo '$(p.nombre)' se creó mientras se subía";
                extra=Dict("archivos_registrados" => ids_creados))
        end
        try
            write(p.ruta, p.datos)
            id_archivo = registrar_archivo_medico(DB_CONN, id_estudio, tipo_archivo, p.ruta;
                                                  formato=p.formato,
                                                  nombre_original=p.nombre,
                                                  metadatos_extra=metadatos)
            push!(ids_creados, id_archivo)
            push!(nombres_creados, p.nombre)
        catch e
            # Compensación manual: sin fila en BD no debe quedar archivo huérfano.
            # `force=true` evita error si el archivo ni siquiera llegó a crearse.
            rm(p.ruta; force=true)
            println("❌ Error guardando '$(p.nombre)' en estudio $id_estudio: ", e)
            # Los archivos anteriores de esta misma petición SÍ quedaron
            # registrados; los informamos para que el cliente lo sepa.
            return error_response(500, "Error guardando '$(p.nombre)': $(sprint(showerror, e))";
                extra=Dict("archivos_registrados" => ids_creados))
        end
    end

    # Devolvemos los registros tal como quedaron en la BD (incluye
    # `fecha_subida`), con 1 sola consulta filtrada por los ids nuevos.
    archivos = try
        ids = Set(ids_creados)
        [a for a in listar_archivos_paciente(DB_CONN, Int(estudio["id_paciente"]))
         if Int(a["id_archivo"]) in ids]
    catch e
        println("⚠️ Archivos guardados pero no se pudieron releer: ", e)
        [Dict{String, Any}("id_archivo" => id, "nombre_original" => n)
         for (id, n) in zip(ids_creados, nombres_creados)]
    end

    println("📁 $(length(archivos)) archivo(s) subidos al estudio $id_estudio ($codigo_paciente)")
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
