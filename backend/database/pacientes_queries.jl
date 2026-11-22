# ==============================================================================
# PacientesQueries — consultas del repositorio histórico de pacientes
# ==============================================================================
#
# Todas las consultas usan parámetros posicionales (`$1`, `$2`, ...): LibPQ
# envía los valores por separado del texto SQL, así que un valor del usuario
# nunca puede "romper" la consulta (inyección SQL).
#
# En Julia, dentro de un string `"..."` el símbolo `$` sirve para interpolar
# variables; por eso en el SQL se escribe `\$1` (un `$` literal).
#
# A diferencia de `Queries` (que devuelve filas crudas de LibPQ), estas
# funciones devuelven `Dict{String,Any}` listos para `json_response`.
#
# Los nombres exportados NO repiten ninguno de `Queries` (p.ej. `crear_archivo`)
# porque ambos módulos se cargan con `using` en Main y Julia marcaría el nombre
# como ambiguo.
# ==============================================================================

module PacientesQueries

using LibPQ
using JSON3

export crear_paciente, obtener_paciente, listar_pacientes
export crear_estudio, obtener_estudio_con_codigo, listar_estudios_paciente
export registrar_archivo_medico, listar_archivos_paciente

# =========================================================
# HELPERS DE CONVERSIÓN Julia <-> PostgreSQL
# =========================================================
#
# Julia tiene dos "vacíos" distintos:
#   - `nothing`: "no hay valor" (lo usamos en los argumentos opcionales y en
#                JSON3, donde `nothing` se escribe como `null`).
#   - `missing`: "valor desconocido", estilo SQL. LibPQ usa `missing` para
#                NULL, tanto al enviar parámetros como al leer resultados.
# Estos helpers traducen entre ambos mundos.

"Convierte `nothing` en `missing` para que LibPQ lo envíe como NULL."
_a_sql(x) = isnothing(x) ? missing : x

"Convierte `missing` (NULL leído de la BD) en `nothing` (→ `null` en JSON)."
_desde_sql(x) = ismissing(x) ? nothing : x

"TIMESTAMP → texto ISO (`2026-11-21T10:00:00`), o `nothing` si es NULL."
_fecha_texto(x) = ismissing(x) ? nothing : string(x)

"""
Prepara un valor para una columna JSONB. Acepta un `Dict`/`JSON3.Object`
(se serializa con `JSON3.write`) o un `String` que ya es JSON. `nothing` o
`missing` → NULL. En el SQL el parámetro va con `::jsonb` para que
PostgreSQL convierta el texto (y rechace JSON inválido).
"""
function _jsonb_a_sql(x)
    (isnothing(x) || ismissing(x)) && return missing
    x isa AbstractString && return String(x)
    return JSON3.write(x)
end

"""
Lee una columna JSONB. LibPQ la entrega como `String`; la parseamos con
`JSON3.read` para que en la respuesta salga como objeto JSON y no como un
texto escapado (`"{\\"a\\":1}"`).
"""
function _jsonb_desde_sql(x)
    ismissing(x) && return nothing
    x isa AbstractString && return JSON3.read(x)
    return x
end

"""
Escapa los comodines de `LIKE`/`ILIKE` (`%`, `_` y la barra de escape) para
que una búsqueda como `"PAC_1"` busque literalmente `_` y no "cualquier
carácter".
"""
_escapar_like(s::AbstractString) = replace(s, "\\" => "\\\\", "%" => "\\%", "_" => "\\_")

# =========================================================
# PACIENTES
# =========================================================

# Columnas en un orden fijo: `_fila_paciente` las lee por posición (f[1], f[2]...).
# Interpolar esta constante en el SQL es seguro porque NO viene del usuario.
const _COLUMNAS_PACIENTE =
    "id_paciente, codigo_paciente, nombre, datos_clinicos, notas, fecha_creacion"

function _fila_paciente(f)
    return Dict{String, Any}(
        "id_paciente"     => f[1],
        "codigo_paciente" => f[2],
        "nombre"          => _desde_sql(f[3]),
        "datos_clinicos"  => _jsonb_desde_sql(f[4]),
        "notas"           => _desde_sql(f[5]),
        "fecha_creacion"  => _fecha_texto(f[6])
    )
end

"""
    crear_paciente(conn, codigo_paciente; nombre, datos_clinicos, notas) -> id_paciente

Inserta un paciente y devuelve su `id_paciente`. Los argumentos después del
`;` son *keyword arguments* (se pasan por nombre, en cualquier orden, y son
opcionales). Si `codigo_paciente` ya existe, LibPQ lanza un error de
violación UNIQUE (el handler lo traducirá a HTTP 409).
"""
function crear_paciente(conn, codigo_paciente::AbstractString;
                        nombre=nothing, datos_clinicos=nothing, notas=nothing)

    sql = """
    INSERT INTO pacientes (
        codigo_paciente,
        nombre,
        datos_clinicos,
        notas
    )
    VALUES (\$1, \$2, \$3::jsonb, \$4)
    RETURNING id_paciente;
    """

    result = execute(conn, sql, [
        codigo_paciente,
        _a_sql(nombre),
        _jsonb_a_sql(datos_clinicos),
        _a_sql(notas)
    ])

    return first(result)[1]

end

"""
    obtener_paciente(conn, id_paciente) -> Dict o nothing

Devuelve el paciente como `Dict`, o `nothing` si no existe.
"""
function obtener_paciente(conn, id_paciente::Integer)

    sql = """
    SELECT $_COLUMNAS_PACIENTE
    FROM pacientes
    WHERE id_paciente = \$1;
    """

    filas = collect(execute(conn, sql, [id_paciente]))
    isempty(filas) && return nothing
    return _fila_paciente(filas[1])

end

"""
    listar_pacientes(conn; busqueda=nothing) -> Vector{Dict}

Lista todos los pacientes (más recientes primero). Si `busqueda` trae texto,
filtra por `codigo_paciente` o `nombre` que lo contengan, sin distinguir
mayúsculas/minúsculas (`ILIKE`). El mismo parámetro `\$1` se usa dos veces.
"""
function listar_pacientes(conn; busqueda=nothing)

    if isnothing(busqueda) || isempty(strip(busqueda))
        sql = """
        SELECT $_COLUMNAS_PACIENTE
        FROM pacientes
        ORDER BY fecha_creacion DESC;
        """
        result = execute(conn, sql)
    else
        patron = "%" * _escapar_like(strip(busqueda)) * "%"
        sql = """
        SELECT $_COLUMNAS_PACIENTE
        FROM pacientes
        WHERE codigo_paciente ILIKE \$1
           OR nombre ILIKE \$1
        ORDER BY fecha_creacion DESC;
        """
        result = execute(conn, sql, [patron])
    end

    # Comprensión de arreglo: aplica `_fila_paciente` a cada fila del resultado.
    return [_fila_paciente(f) for f in result]

end

# =========================================================
# ESTUDIOS
# =========================================================

const _COLUMNAS_ESTUDIO =
    "e.id_estudio, e.id_paciente, e.modalidad, e.fecha_estudio, e.descripcion, e.fecha_creacion"

function _fila_estudio(f)
    return Dict{String, Any}(
        "id_estudio"     => f[1],
        "id_paciente"    => f[2],
        "modalidad"      => _desde_sql(f[3]),
        "fecha_estudio"  => _fecha_texto(f[4]),
        "descripcion"    => _desde_sql(f[5]),
        "fecha_creacion" => _fecha_texto(f[6])
    )
end

"""
    crear_estudio(conn, id_paciente; modalidad, fecha_estudio, descripcion) -> id_estudio

`fecha_estudio` puede ser un texto ISO (`"2026-11-21"` o
`"2026-11-21T10:30:00"`) o un `DateTime`; PostgreSQL lo convierte con
`::timestamp` (y lanza error si el formato es inválido).
"""
function crear_estudio(conn, id_paciente::Integer;
                       modalidad=nothing, fecha_estudio=nothing, descripcion=nothing)

    sql = """
    INSERT INTO estudios (
        id_paciente,
        modalidad,
        fecha_estudio,
        descripcion
    )
    VALUES (\$1, \$2, \$3::timestamp, \$4)
    RETURNING id_estudio;
    """

    result = execute(conn, sql, [
        id_paciente,
        _a_sql(modalidad),
        _a_sql(fecha_estudio),
        _a_sql(descripcion)
    ])

    return first(result)[1]

end

"""
    obtener_estudio_con_codigo(conn, id_estudio) -> Dict o nothing

Devuelve el estudio junto con el `codigo_paciente` de su paciente (JOIN).
Lo necesita la subida de archivos (Bloque 3) para armar la carpeta
`_pacientes/<codigo>/estudio_<id>`.
"""
function obtener_estudio_con_codigo(conn, id_estudio::Integer)

    sql = """
    SELECT $_COLUMNAS_ESTUDIO, p.codigo_paciente
    FROM estudios e
    JOIN pacientes p ON p.id_paciente = e.id_paciente
    WHERE e.id_estudio = \$1;
    """

    filas = collect(execute(conn, sql, [id_estudio]))
    isempty(filas) && return nothing

    estudio = _fila_estudio(filas[1])
    estudio["codigo_paciente"] = filas[1][7]
    return estudio

end

"""
    listar_estudios_paciente(conn, id_paciente) -> Vector{Dict}

Estudios de un paciente, del más reciente al más antiguo (los que no tienen
`fecha_estudio` van al final).
"""
function listar_estudios_paciente(conn, id_paciente::Integer)

    sql = """
    SELECT $_COLUMNAS_ESTUDIO
    FROM estudios e
    WHERE e.id_paciente = \$1
    ORDER BY e.fecha_estudio DESC NULLS LAST, e.id_estudio DESC;
    """

    return [_fila_estudio(f) for f in execute(conn, sql, [id_paciente])]

end

# =========================================================
# ARCHIVOS MÉDICOS
# =========================================================

function _fila_archivo(f)
    return Dict{String, Any}(
        "id_archivo"      => f[1],
        "id_estudio"      => f[2],
        "tipo_archivo"    => f[3],
        "formato"         => _desde_sql(f[4]),
        "nombre_original" => _desde_sql(f[5]),
        "ruta_absoluta"   => f[6],
        "metadatos_extra" => _jsonb_desde_sql(f[7]),
        "fecha_subida"    => _fecha_texto(f[8])
    )
end

"""
    registrar_archivo_medico(conn, id_estudio, tipo_archivo, ruta_absoluta;
                             formato, nombre_original, metadatos_extra) -> id_archivo

Registra en BD un archivo que YA fue escrito en disco. Solo guarda la ruta
y metadatos, nunca el contenido.
"""
function registrar_archivo_medico(conn, id_estudio::Integer,
                                  tipo_archivo::AbstractString,
                                  ruta_absoluta::AbstractString;
                                  formato=nothing, nombre_original=nothing,
                                  metadatos_extra=nothing)

    sql = """
    INSERT INTO archivos_medicos (
        id_estudio,
        tipo_archivo,
        formato,
        nombre_original,
        ruta_absoluta,
        metadatos_extra
    )
    VALUES (\$1, \$2, \$3, \$4, \$5, \$6::jsonb)
    RETURNING id_archivo;
    """

    result = execute(conn, sql, [
        id_estudio,
        tipo_archivo,
        _a_sql(formato),
        _a_sql(nombre_original),
        ruta_absoluta,
        _jsonb_a_sql(metadatos_extra)
    ])

    return first(result)[1]

end

"""
    listar_archivos_paciente(conn, id_paciente) -> Vector{Dict}

Todos los archivos de todos los estudios de un paciente en UNA sola
consulta (JOIN con `estudios`). Cada Dict trae `id_estudio`, así el handler
puede agruparlos por estudio sin hacer una consulta por cada estudio.
"""
function listar_archivos_paciente(conn, id_paciente::Integer)

    sql = """
    SELECT
        a.id_archivo,
        a.id_estudio,
        a.tipo_archivo,
        a.formato,
        a.nombre_original,
        a.ruta_absoluta,
        a.metadatos_extra,
        a.fecha_subida
    FROM archivos_medicos a
    JOIN estudios e ON e.id_estudio = a.id_estudio
    WHERE e.id_paciente = \$1
    ORDER BY a.id_estudio, a.fecha_subida, a.id_archivo;
    """

    return [_fila_archivo(f) for f in execute(conn, sql, [id_paciente])]

end

end
