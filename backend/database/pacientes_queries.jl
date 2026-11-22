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

export crear_paciente, obtener_paciente, obtener_paciente_por_codigo, listar_pacientes
export actualizar_paciente, eliminar_paciente
export crear_estudio, obtener_estudio_con_paciente, listar_estudios_paciente
export actualizar_estudio, eliminar_estudio
export registrar_archivos_medicos, listar_archivos_paciente, listar_archivos_estudio
export obtener_archivo_medico, obtener_archivo_medico_interno
export actualizar_archivo_medico, eliminar_archivo_medico, eliminar_archivos_medicos
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

"""
    _actualizar_fila(conn, tabla, columna_id, id, cambios, editables, retorno) -> fila o nothing

Arma y ejecuta un `UPDATE ... RETURNING` SOLO con las columnas recibidas
(edición parcial). `cambios` es una colección de pares `"columna" => valor`
(`nothing` → NULL, es decir, "limpiar"). `editables` es la lista blanca
`columna => cast SQL` (`""`, `"::jsonb"`, `"::timestamp"`):
- los NOMBRES de columna nunca vienen del usuario: se comprueban contra esa
  lista, así interpolarlos en el SQL es seguro;
- los VALORES viajan como parámetros `\$2, \$3, ...` (`\$1` es el id).
Siempre actualiza `fecha_actualizacion` en UTC. Devuelve la fila de
`RETURNING` o `nothing` si no existe el id.
"""
function _actualizar_fila(conn, tabla::AbstractString, columna_id::AbstractString,
                          id::Integer, cambios, editables::AbstractDict,
                          retorno::AbstractString)
    isempty(cambios) && throw(ArgumentError("No hay columnas que actualizar"))

    valores = Any[id]            # `Any[...]`: vector que admite tipos mezclados
    asignaciones = String[]
    for (columna, valor) in cambios
        cast = get(editables, columna, nothing)
        isnothing(cast) && throw(ArgumentError("Columna no editable: $columna"))
        push!(valores, cast == "::jsonb" ? _jsonb_a_sql(valor) : _a_sql(valor))
        # `\$` es un `$` literal y `$(...)` interpola: "nombre = \$2"
        push!(asignaciones, "$columna = \$$(length(valores))$cast")
    end
    push!(asignaciones, "fecha_actualizacion = NOW() AT TIME ZONE 'UTC'")

    sql = """
    UPDATE $tabla
    SET $(join(asignaciones, ", "))
    WHERE $columna_id = \$1
    RETURNING $retorno;
    """

    filas = collect(execute(conn, sql, valores))
    return isempty(filas) ? nothing : filas[1]
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
    obtener_paciente_por_codigo(conn, codigo) -> Dict o nothing

Busca por coincidencia EXACTA sin distinguir mayúsculas. Se escribe
`lower(codigo_paciente) = lower(\$1)` (y no `ILIKE`) para que PostgreSQL
pueda usar el índice único sobre `lower(codigo_paciente)` y para que `_` o
`%` no actúen como comodines. Como el índice es único, hay 0 o 1 fila.
"""
function obtener_paciente_por_codigo(conn, codigo::AbstractString)

    sql = """
    SELECT $_COLUMNAS_PACIENTE
    FROM pacientes
    WHERE lower(codigo_paciente) = lower(\$1);
    """

    filas = collect(execute(conn, sql, [String(codigo)]))
    isempty(filas) && return nothing
    return _fila_paciente(filas[1])

end

# Resumen para el listado: SIN `datos_clinicos` ni `notas` (no inflar la
# respuesta ni exponer datos clínicos en una vista de tabla).
function _fila_resumen_paciente(f)
    return Dict{String, Any}(
        "id_paciente"          => _id(f[1]),
        "codigo_paciente"      => f[2],
        "nombre"               => _desde_sql(f[3]),
        "fecha_creacion"       => _fecha_texto(f[4]),
        "fecha_actualizacion"  => _fecha_texto(f[5]),
        "num_estudios"         => Int(f[6]),          # COUNT(*) llega como Int64
        "ultima_fecha_estudio" => _fecha_texto(f[7])  # MAX(...) es NULL si no hay fechas
    )
end

"""
    listar_pacientes(conn; busqueda, limite, desplazamiento) -> (; pacientes, total)

Listado RESUMIDO y paginado (más recientes primero; el `id` desempata para
que el orden sea estable entre páginas). Si `busqueda` trae texto, filtra
por `codigo_paciente` o `nombre` que lo contengan (`ILIKE`, sin distinguir
mayúsculas). Devuelve una NamedTuple: `pacientes` (la página) y `total`
(cuántos pacientes cumplen el filtro, para que el frontend pinte la
paginación).

`\$1::text IS NULL OR ...` permite usar UN solo SQL con o sin filtro: si
no hay búsqueda se envía NULL y la condición es siempre verdadera.
El `LEFT JOIN LATERAL` es una subconsulta que se evalúa "por cada paciente"
(puede ver `p.id_paciente`); con `COUNT`/`MAX` sin `GROUP BY` siempre
devuelve exactamente una fila (0 / NULL si no tiene estudios).
"""
function listar_pacientes(conn; busqueda=nothing, limite::Integer=20,
                          desplazamiento::Integer=0)

    patron = (isnothing(busqueda) || isempty(strip(busqueda))) ? missing :
             "%" * _escapar_like(strip(busqueda)) * "%"

    # Interpolar `filtro` es seguro: es texto fijo nuestro, el valor va en `\$1`.
    filtro = "(\$1::text IS NULL OR p.codigo_paciente ILIKE \$1 OR p.nombre ILIKE \$1)"

    sql_total = """
    SELECT COUNT(*)
    FROM pacientes p
    WHERE $filtro;
    """
    total = Int(first(execute(conn, sql_total, Any[patron]))[1])

    sql = """
    SELECT p.id_paciente, p.codigo_paciente, p.nombre,
           p.fecha_creacion, p.fecha_actualizacion,
           s.num_estudios, s.ultima_fecha_estudio
    FROM pacientes p
    LEFT JOIN LATERAL (
        SELECT COUNT(*)             AS num_estudios,
               MAX(e.fecha_estudio) AS ultima_fecha_estudio
        FROM estudios e
        WHERE e.id_paciente = p.id_paciente
    ) s ON TRUE
    WHERE $filtro
    ORDER BY p.fecha_creacion DESC, p.id_paciente DESC
    LIMIT \$2 OFFSET \$3;
    """
    result = execute(conn, sql, Any[patron, limite, desplazamiento])

    # Comprensión de arreglo: aplica `_fila_resumen_paciente` a cada fila.
    pacientes = [_fila_resumen_paciente(f) for f in result]
    return (; pacientes = pacientes, total = total)

end

# Lista blanca de columnas editables con PUT (columna => cast SQL).
const _EDITABLES_PACIENTE = Dict(
    "codigo_paciente" => "",
    "nombre"          => "",
    "datos_clinicos"  => "::jsonb",
    "notas"           => ""
)

"""
    actualizar_paciente(conn, id_paciente, cambios) -> Dict o nothing

Edición parcial: solo cambia las columnas presentes en `cambios` (pares
`"columna" => valor`; `nothing` limpia la columna). Devuelve el paciente
actualizado o `nothing` si no existe. Si el nuevo `codigo_paciente` choca
con otro, LibPQ lanza una violación UNIQUE (el handler responde 409).
"""
function actualizar_paciente(conn, id_paciente::Integer, cambios)
    fila = _actualizar_fila(conn, "pacientes", "id_paciente", id_paciente,
                            cambios, _EDITABLES_PACIENTE, _COLUMNAS_PACIENTE)
    return isnothing(fila) ? nothing : _fila_paciente(fila)
end

"""
    eliminar_paciente(conn, id_paciente) -> Int o nothing

Borra el paciente con UNA sentencia (atómica). `ON DELETE CASCADE` elimina
también sus estudios y archivos_medicos. Devuelve el id borrado o `nothing`
si no existía (así no hace falta un SELECT previo).
"""
function eliminar_paciente(conn, id_paciente::Integer)

    sql = """
    DELETE FROM pacientes
    WHERE id_paciente = \$1
    RETURNING id_paciente;
    """

    filas = collect(execute(conn, sql, [id_paciente]))
    return isempty(filas) ? nothing : Int(filas[1][1])

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

const _EDITABLES_ESTUDIO = Dict(
    "modalidad"     => "",
    "fecha_estudio" => "::timestamp",   # texto ISO (UTC, sin Z) ya validado
    "descripcion"   => ""
)

"""
    actualizar_estudio(conn, id_estudio, cambios) -> Dict o nothing

Edición parcial del estudio (ver `_actualizar_fila`). En `UPDATE` el alias
`AS e` permite reutilizar `RETURNING $_COLUMNAS_ESTUDIO` (columnas `e.`);
en el `SET` las columnas van sin alias, como exige PostgreSQL.
"""
function actualizar_estudio(conn, id_estudio::Integer, cambios)
    fila = _actualizar_fila(conn, "estudios AS e", "e.id_estudio", id_estudio,
                            cambios, _EDITABLES_ESTUDIO, _COLUMNAS_ESTUDIO)
    return isnothing(fila) ? nothing : _fila_estudio(fila)
end

"""
    eliminar_estudio(conn, id_estudio) -> NamedTuple o nothing

Borra el estudio en una sola sentencia; la cascada elimina sus
archivos_medicos. Devuelve `(; id_estudio, id_paciente)` (el handler lo
necesita para ubicar la carpeta en disco) o `nothing` si no existía.
"""
function eliminar_estudio(conn, id_estudio::Integer)

    sql = """
    DELETE FROM estudios
    WHERE id_estudio = \$1
    RETURNING id_estudio, id_paciente;
    """

    filas = collect(execute(conn, sql, [id_estudio]))
    isempty(filas) && return nothing
    return (; id_estudio = Int(filas[1][1]), id_paciente = Int(filas[1][2]))

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

"""
    listar_archivos_estudio(conn, id_estudio; tipo_archivo, formato) -> Vector{Dict}

Archivos (forma pública) de un estudio, en orden de subida. Los filtros son
opcionales: si llegan como `nothing` se envían NULL y `\$2::text IS NULL`
hace que esa condición no filtre nada. Los valores ya vienen validados y
normalizados por el handler.
"""
function listar_archivos_estudio(conn, id_estudio::Integer;
                                 tipo_archivo=nothing, formato=nothing)

    sql = """
    SELECT $_COLUMNAS_ARCHIVO
    FROM archivos_medicos a
    WHERE a.id_estudio = \$1
      AND (\$2::text IS NULL OR a.tipo_archivo = \$2)
      AND (\$3::text IS NULL OR a.formato = \$3)
    ORDER BY a.fecha_subida, a.id_archivo;
    """

    params = Any[id_estudio, _a_sql(tipo_archivo), _a_sql(formato)]
    return [_fila_archivo(f) for f in execute(conn, sql, params)]

end

"""
    obtener_archivo_medico(conn, id_archivo) -> Dict o nothing

Forma PÚBLICA del archivo (con `url_descarga`, sin `ruta_relativa`).
"""
function obtener_archivo_medico(conn, id_archivo::Integer)

    sql = """
    SELECT $_COLUMNAS_ARCHIVO
    FROM archivos_medicos a
    WHERE a.id_archivo = \$1;
    """

    filas = collect(execute(conn, sql, [id_archivo]))
    isempty(filas) && return nothing
    return _fila_archivo(filas[1])

end

const _EDITABLES_ARCHIVO = Dict(
    "tipo_archivo"    => "",
    "metadatos_extra" => "::jsonb"
)

"""
    actualizar_archivo_medico(conn, id_archivo, cambios) -> Dict o nothing

Edición parcial de metadatos del archivo. NO toca el archivo físico ni su
`ruta_relativa` (no está en la lista blanca). Devuelve la forma pública.
"""
function actualizar_archivo_medico(conn, id_archivo::Integer, cambios)
    fila = _actualizar_fila(conn, "archivos_medicos AS a", "a.id_archivo", id_archivo,
                            cambios, _EDITABLES_ARCHIVO, _COLUMNAS_ARCHIVO)
    return isnothing(fila) ? nothing : _fila_archivo(fila)
end

"""
    eliminar_archivo_medico(conn, id_archivo) -> NamedTuple o nothing

USO INTERNO. Borra UN registro (distinto de `eliminar_archivos_medicos`,
que es la compensación en lote de la subida) y devuelve
`(; id_archivo, ruta_relativa)` para que el handler borre el archivo en
disco. `nothing` si no existía. La `ruta_relativa` NO debe enviarse al cliente.
"""
function eliminar_archivo_medico(conn, id_archivo::Integer)

    sql = """
    DELETE FROM archivos_medicos
    WHERE id_archivo = \$1
    RETURNING id_archivo, ruta_relativa;
    """

    filas = collect(execute(conn, sql, [id_archivo]))
    isempty(filas) && return nothing
    return (; id_archivo = Int(filas[1][1]), ruta_relativa = String(filas[1][2]))

end

end
