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
# funciones devuelven `Dict{String,Any}` listos para `json_response`, con un
# contrato estable:
#   - IDs siempre `Int` (LibPQ entrega INTEGER como `Int32`).
#   - Fechas en ISO-8601 UTC con `Z` final: "2026-11-21T10:30:00Z".
#   - Los archivos NUNCA exponen rutas del servidor (solo `url_descarga`).
#
# Los nombres exportados NO repiten ninguno de `Queries` (p.ej. `crear_archivo`)
# porque ambos módulos se cargan con `using` en Main y Julia marcaría el nombre
# como ambiguo.
# ==============================================================================

module PacientesQueries

using LibPQ
using JSON3
using Dates

export crear_paciente, obtener_paciente, listar_pacientes
export crear_estudio, obtener_estudio_con_paciente, listar_estudios_paciente
export registrar_archivos_medicos, listar_archivos_paciente
export obtener_archivo_medico_interno, eliminar_archivos_medicos
export es_violacion_unica, es_violacion_fk

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

"ID leído de la BD (`Int32`) → `Int`, para que el tipo sea uniforme en Julia."
_id(x) = ismissing(x) ? nothing : Int(x)

# `\\T` escapa la `T` para que se imprima literal entre fecha y hora.
# Se crea una sola vez: construir un DateFormat tiene costo.
const _FORMATO_ISO_UTC = Dates.DateFormat("yyyy-mm-dd\\THH:MM:SS")

"""
TIMESTAMP → texto ISO-8601 UTC con `Z` (`"2026-11-21T10:30:00Z"`), o
`nothing` si es NULL. Las columnas guardan UTC (ver pacientes_schema.jl),
por eso añadir la `Z` es correcto. Se omiten los milisegundos a propósito.
"""
function _fecha_texto(x)
    ismissing(x) && return nothing
    x isa Dates.DateTime && return Dates.format(x, _FORMATO_ISO_UTC) * "Z"
    x isa Dates.Date && return Dates.format(Dates.DateTime(x), _FORMATO_ISO_UTC) * "Z"
    return string(x)   # respaldo para un tipo inesperado
end

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

"""
Convierte un vector de Julia en un *literal de arreglo* de PostgreSQL
(`{"a","b",NULL}` o `{1,2}`), que luego se envía como UN parámetro y se
castea en el SQL (`\$2::text[]`). Construimos el texto nosotros mismos para
no depender de cómo LibPQ.jl serializa arreglos. Reglas de PostgreSQL:
cada texto va entre comillas dobles y dentro se escapan `\\` y `"`;
`nothing`/`missing` se escribe `NULL` sin comillas.
"""
function _arreglo_pg(valores)
    io = IOBuffer()
    print(io, '{')
    for (i, v) in enumerate(valores)
        i > 1 && print(io, ',')
        if isnothing(v) || ismissing(v)
            print(io, "NULL")
        elseif v isa Integer
            print(io, v)
        else
            # `replace` con varios pares los aplica a la vez (no re-escapa).
            print(io, '"', replace(string(v), "\\" => "\\\\", "\"" => "\\\""), '"')
        end
    end
    print(io, '}')
    return String(take!(io))
end

# =========================================================
# DETECCIÓN DE ERRORES DE RESTRICCIÓN (SQLSTATE)
# =========================================================

"""
Devuelve `true` si `e` es el error de PostgreSQL indicado. Prueba, en orden:
1. el tipo específico de LibPQ (`LibPQ.Errors.<tipo>`), si existe;
2. el nombre del tipo de la excepción;
3. el código SQLSTATE o textos típicos dentro del mensaje (respaldo).
`isdefined` evita fallar si la versión instalada de LibPQ no define el tipo.
"""
function _es_error_sql(e, tipo::Symbol, sqlstate::AbstractString, textos::AbstractString...)
    if isdefined(LibPQ, :Errors) && isdefined(LibPQ.Errors, tipo)
        T = getfield(LibPQ.Errors, tipo)
        T isa Type && e isa T && return true
    end
    nameof(typeof(e)) == tipo && return true
    mensaje = try
        sprint(showerror, e)
    catch
        ""
    end
    return occursin(sqlstate, mensaje) || any(t -> occursin(t, mensaje), textos)
end

"`true` si `e` es una violación de UNIQUE (SQLSTATE 23505)."
es_violacion_unica(e) =
    _es_error_sql(e, :UniqueViolation, "23505", "duplicate key", "llave duplicada")

"`true` si `e` es una violación de FOREIGN KEY (SQLSTATE 23503)."
es_violacion_fk(e) =
    _es_error_sql(e, :ForeignKeyViolation, "23503", "violates foreign key", "llave foránea")

# =========================================================
# PACIENTES
# =========================================================

# Columnas en un orden fijo: `_fila_paciente` las lee por posición (f[1], f[2]...).
# Interpolar esta constante en el SQL es seguro porque NO viene del usuario.
const _COLUMNAS_PACIENTE =
    "id_paciente, codigo_paciente, nombre, datos_clinicos, notas, " *
    "fecha_creacion, fecha_actualizacion"

function _fila_paciente(f)
    return Dict{String, Any}(
        "id_paciente"         => _id(f[1]),
        "codigo_paciente"     => f[2],
        "nombre"              => _desde_sql(f[3]),
        "datos_clinicos"      => _jsonb_desde_sql(f[4]),
        "notas"               => _desde_sql(f[5]),
        "fecha_creacion"      => _fecha_texto(f[6]),
        "fecha_actualizacion" => _fecha_texto(f[7])
    )
end

"""
    crear_paciente(conn, codigo_paciente; nombre, datos_clinicos, notas) -> Dict

Inserta un paciente y devuelve el registro completo gracias a `RETURNING`
(una sola ida a la BD, sin SELECT posterior). Los argumentos después del `;`
son *keyword arguments* (opcionales, se pasan por nombre). Si el código ya
existe (sin distinguir mayúsculas) LibPQ lanza una violación UNIQUE; el
handler la detecta con `es_violacion_unica` y responde 409.
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
    RETURNING $_COLUMNAS_PACIENTE;
    """

    result = execute(conn, sql, [
        codigo_paciente,
        _a_sql(nombre),
        _jsonb_a_sql(datos_clinicos),
        _a_sql(notas)
    ])

    return _fila_paciente(first(result))

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

Lista todos los pacientes (más recientes primero; el `id` desempata, igual
que el índice `idx_pacientes_orden`). Si `busqueda` trae texto, filtra por
`codigo_paciente` o `nombre` que lo contengan, sin distinguir
mayúsculas/minúsculas (`ILIKE`). El mismo parámetro `\$1` se usa dos veces.
"""
function listar_pacientes(conn; busqueda=nothing)

    if isnothing(busqueda) || isempty(strip(busqueda))
        sql = """
        SELECT $_COLUMNAS_PACIENTE
        FROM pacientes
        ORDER BY fecha_creacion DESC, id_paciente DESC;
        """
        result = execute(conn, sql)
    else
        patron = "%" * _escapar_like(strip(busqueda)) * "%"
        sql = """
        SELECT $_COLUMNAS_PACIENTE
        FROM pacientes
        WHERE codigo_paciente ILIKE \$1
           OR nombre ILIKE \$1
        ORDER BY fecha_creacion DESC, id_paciente DESC;
        """
        result = execute(conn, sql, [patron])
    end

    # Comprensión de arreglo: aplica `_fila_paciente` a cada fila del resultado.
    return [_fila_paciente(f) for f in result]

end

# =========================================================
# ESTUDIOS
# =========================================================

# Con prefijo `e.` porque se usa en JOINs (pacientes también tiene
# `id_paciente`, `fecha_creacion`...). En el INSERT se usa `estudios AS e`
# para que el mismo `RETURNING $_COLUMNAS_ESTUDIO` sea válido.
const _COLUMNAS_ESTUDIO =
    "e.id_estudio, e.id_paciente, e.modalidad, e.fecha_estudio, e.descripcion, " *
    "e.fecha_creacion, e.fecha_actualizacion"

function _fila_estudio(f)
    return Dict{String, Any}(
        "id_estudio"          => _id(f[1]),
        "id_paciente"         => _id(f[2]),
        "modalidad"           => _desde_sql(f[3]),
        "fecha_estudio"       => _fecha_texto(f[4]),
        "descripcion"         => _desde_sql(f[5]),
        "fecha_creacion"      => _fecha_texto(f[6]),
        "fecha_actualizacion" => _fecha_texto(f[7])
    )
end

"""
    crear_estudio(conn, id_paciente; modalidad, fecha_estudio, descripcion) -> Dict

Inserta el estudio y devuelve el registro completo (`RETURNING`).
`fecha_estudio` es un texto ISO ya validado por el handler (UTC, sin `Z`);
PostgreSQL lo convierte con `::timestamp`. Si el paciente no existe, la FK
lanza una violación (SQLSTATE 23503) que el handler traduce a 404: así no
hace falta un SELECT previo (y no hay carrera si el paciente se borra justo
entre el chequeo y el INSERT).
"""
function crear_estudio(conn, id_paciente::Integer;
                       modalidad=nothing, fecha_estudio=nothing, descripcion=nothing)

    sql = """
    INSERT INTO estudios AS e (
        id_paciente,
        modalidad,
        fecha_estudio,
        descripcion
    )
    VALUES (\$1, \$2, \$3::timestamp, \$4)
    RETURNING $_COLUMNAS_ESTUDIO;
    """

    result = execute(conn, sql, [
        id_paciente,
        _a_sql(modalidad),
        _a_sql(fecha_estudio),
        _a_sql(descripcion)
    ])

    return _fila_estudio(first(result))

end

"""
    obtener_estudio_con_paciente(conn, id_estudio) -> Dict o nothing

Devuelve el estudio con la forma estándar del recurso `Estudio` (la misma
de `crear_estudio`/`listar_estudios_paciente`), que ya incluye
`id_paciente`. Lo usa la subida de archivos para armar la carpeta
`_pacientes/paciente_<id>/estudio_<id>`. No necesita JOIN: la carpeta ya no
depende de `codigo_paciente`.
"""
function obtener_estudio_con_paciente(conn, id_estudio::Integer)

    sql = """
    SELECT $_COLUMNAS_ESTUDIO
    FROM estudios e
    WHERE e.id_estudio = \$1;
    """

    filas = collect(execute(conn, sql, [id_estudio]))
    isempty(filas) && return nothing
    return _fila_estudio(filas[1])

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

# Columnas PÚBLICAS: `ruta_relativa` NO está aquí a propósito, para que
# ninguna respuesta JSON pueda filtrar la estructura de carpetas del servidor.
const _COLUMNAS_ARCHIVO =
    "a.id_archivo, a.id_estudio, a.tipo_archivo, a.formato, a.nombre_original, " *
    "a.tamano_bytes, a.metadatos_extra, a.fecha_subida, a.fecha_actualizacion"

function _fila_archivo(f)
    id_archivo = _id(f[1])
    return Dict{String, Any}(
        "id_archivo"          => id_archivo,
        "id_estudio"          => _id(f[2]),
        "tipo_archivo"        => f[3],
        "formato"             => _desde_sql(f[4]),
        "nombre_original"     => f[5],
        "tamano_bytes"        => Int(f[6]),
        "metadatos_extra"     => _jsonb_desde_sql(f[7]),
        "fecha_subida"        => _fecha_texto(f[8]),
        "fecha_actualizacion" => _fecha_texto(f[9]),
        "url_descarga"        => "/api/archivos/$(id_archivo)/descarga"
    )
end

"""
    registrar_archivos_medicos(conn, id_estudio, lista) -> Vector{Dict}

Registra VARIOS archivos (ya escritos en disco) con UN solo `INSERT`.
`lista` es un vector de NamedTuples con los campos `tipo_archivo`, `formato`,
`nombre_original`, `ruta_relativa`, `tamano_bytes` y `metadatos_extra`.

¿Por qué es atómico sin BEGIN/COMMIT? En PostgreSQL cada sentencia es su
propia transacción implícita: si UNA fila viola `uq_archivos_ruta_relativa`
o la FK, no se inserta NINGUNA. Esto evita abrir transacciones sobre la
conexión global compartida (`DB_CONN`).

Técnica: cada columna viaja como un arreglo (`\$2::text[]`, ...) y `unnest`
los "despliega" en filas en paralelo (el elemento i de cada arreglo forma la
fila i). `WITH ORDINALITY` numera las filas para insertarlas en el orden
recibido; así los `id_archivo` siguen ese orden.
"""
function registrar_archivos_medicos(conn, id_estudio::Integer, lista)

    isempty(lista) && return Dict{String, Any}[]

    sql = """
    INSERT INTO archivos_medicos AS a (
        id_estudio,
        tipo_archivo,
        formato,
        nombre_original,
        ruta_relativa,
        tamano_bytes,
        metadatos_extra
    )
    SELECT
        \$1::integer,
        t.tipo_archivo,
        t.formato,
        t.nombre_original,
        t.ruta_relativa,
        t.tamano_bytes,
        t.metadatos_extra::jsonb
    FROM unnest(\$2::text[], \$3::text[], \$4::text[], \$5::text[], \$6::bigint[], \$7::text[])
         WITH ORDINALITY AS t(tipo_archivo, formato, nombre_original,
                              ruta_relativa, tamano_bytes, metadatos_extra, orden)
    ORDER BY t.orden
    RETURNING $_COLUMNAS_ARCHIVO;
    """

    # `[x.campo for x in lista]` arma una columna a partir de la lista de filas.
    result = execute(conn, sql, [
        id_estudio,
        _arreglo_pg([x.tipo_archivo for x in lista]),
        _arreglo_pg([x.formato for x in lista]),
        _arreglo_pg([x.nombre_original for x in lista]),
        _arreglo_pg([x.ruta_relativa for x in lista]),
        _arreglo_pg([Int(x.tamano_bytes) for x in lista]),
        _arreglo_pg([_jsonb_a_sql(x.metadatos_extra) for x in lista])
    ])

    archivos = [_fila_archivo(f) for f in result]
    # RETURNING no garantiza orden; ordenamos por id (que sigue el de entrada).
    sort!(archivos; by = a -> a["id_archivo"])
    return archivos

end

"""
    eliminar_archivos_medicos(conn, ids) -> nothing

Borra los registros indicados con un solo `DELETE`. Lo usa el handler de
subida como compensación si, tras el INSERT, falla el renombrado en disco
(para no dejar filas apuntando a archivos inexistentes).
"""
function eliminar_archivos_medicos(conn, ids)

    isempty(ids) && return nothing

    sql = """
    DELETE FROM archivos_medicos
    WHERE id_archivo = ANY(\$1::integer[]);
    """

    execute(conn, sql, [_arreglo_pg([Int(i) for i in ids])])
    return nothing

end

"""
    obtener_archivo_medico_interno(conn, id_archivo) -> NamedTuple o nothing

USO INTERNO (operaciones de disco: descarga/borrado, Bloque F2-2). Es la
única función que devuelve `ruta_relativa`; su resultado NO debe enviarse
tal cual al cliente. Devuelve una NamedTuple (no un Dict) para que se note
que no es el recurso público.
"""
function obtener_archivo_medico_interno(conn, id_archivo::Integer)

    sql = """
    SELECT a.id_archivo, a.id_estudio, a.nombre_original, a.formato,
           a.tamano_bytes, a.ruta_relativa
    FROM archivos_medicos a
    WHERE a.id_archivo = \$1;
    """

    filas = collect(execute(conn, sql, [id_archivo]))
    isempty(filas) && return nothing
    f = filas[1]
    return (; id_archivo      = Int(f[1]),
              id_estudio      = Int(f[2]),
              nombre_original = String(f[3]),
              formato         = _desde_sql(f[4]),
              tamano_bytes    = Int(f[5]),
              ruta_relativa   = String(f[6]))

end

"""
    listar_archivos_paciente(conn, id_paciente) -> Vector{Dict}

Todos los archivos de todos los estudios de un paciente en UNA sola
consulta (JOIN con `estudios`). Cada Dict trae `id_estudio`, así el handler
puede agruparlos por estudio sin hacer una consulta por cada estudio.
"""
function listar_archivos_paciente(conn, id_paciente::Integer)

    sql = """
    SELECT $_COLUMNAS_ARCHIVO
    FROM archivos_medicos a
    JOIN estudios e ON e.id_estudio = a.id_estudio
    WHERE e.id_paciente = \$1
    ORDER BY a.id_estudio, a.fecha_subida, a.id_archivo;
    """

    return [_fila_archivo(f) for f in execute(conn, sql, [id_paciente])]

end

end
