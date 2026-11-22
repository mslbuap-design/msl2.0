# ==============================================================================
# Handlers del repositorio histórico de pacientes (Bloque 2: CRUD básico)
# ==============================================================================
#
# Jerarquía: Paciente -> Estudio -> Archivo médico (ver SPEC.md).
# Las consultas viven en `PacientesQueries` (database/pacientes_queries.jl);
# aquí solo validamos la entrada HTTP y armamos la respuesta JSON.
#
# Este archivo se incluye desde server.jl en el ámbito `Main`, así que ya
# tiene disponibles `DB_CONN`, `json_response`, `error_response`,
# `leer_body_json`, `parse_int_seguro`, `registrar_ruta!`, `HTTP`, `JSON3`
# y `Dates`.
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
# REGISTRO DE RUTAS
# =========================================================
registrar_ruta!("GET",  "/api/pacientes", handler_listar_pacientes)
registrar_ruta!("POST", "/api/pacientes", handler_crear_paciente)
registrar_ruta!("GET",  "/api/pacientes/:id", handler_obtener_paciente)
registrar_ruta!("POST", "/api/pacientes/:id/estudios", handler_crear_estudio)
