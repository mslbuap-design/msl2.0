module Queries

using LibPQ

export crear_proyecto
export crear_grupo
export crear_archivo

export obtener_proyecto
export obtener_proyectos
export listar_proyectos
export obtener_grupos
export obtener_archivos

export crear_resultado
export guardar_feature
export guardar_estadistica
export guardar_mascara

export obtener_features

# Nuevas — soporte para eliminar/renombrar proyecto y renombrar carpeta
export eliminar_proyecto
export renombrar_proyecto
export obtener_grupo_por_nombre
export renombrar_grupo
export archivos_bajo_proyecto
export archivos_bajo_grupo
export actualizar_ruta_archivo
export actualizar_rutas_por_prefijo!
export obtener_proyecto_por_ruta

# =========================================================
# PROYECTOS
# =========================================================

function crear_proyecto(conn, nombre, ruta_base)

    sql = """
    INSERT INTO proyectos (
        nombre,
        ruta_base
    )
    VALUES (\$1, \$2)
    RETURNING id;
    """

    result = execute(conn, sql, [
        nombre,
        ruta_base
    ])

    return first(result)[1]

end

# =========================================================
# OBTENER PROYECTO POR ID
# =========================================================

function obtener_proyecto(conn, proyecto_id)

    sql = """
    SELECT
        id,
        nombre,
        ruta_base,
        fecha_creacion
    FROM proyectos
    WHERE id = \$1;
    """

    result = execute(conn, sql, [proyecto_id])

    return collect(result)

end

# =========================================================
# OBTENER PROYECTO POR RUTA
# =========================================================
# Usado por `agregar-archivos` para saber a qué proyecto/grupo pertenece
# un archivo que se está registrando, sin depender de ningún "proyecto
# actual" global — el frontend ya manda `ruta_proyecto` explícito.

function obtener_proyecto_por_ruta(conn, ruta_base)

    sql = """
    SELECT
        id,
        nombre,
        ruta_base,
        fecha_creacion
    FROM proyectos
    WHERE ruta_base = \$1;
    """

    return collect(execute(conn, sql, [ruta_base]))

end

# =========================================================
# OBTENER TODOS LOS PROYECTOS
# =========================================================

function obtener_proyectos(conn)

    sql = """
    SELECT
        id,
        nombre,
        ruta_base,
        fecha_creacion
    FROM proyectos
    ORDER BY fecha_creacion DESC;
    """

    return execute(conn, sql)

end

# =========================================================
# LISTAR PROYECTOS
# =========================================================

function listar_proyectos(conn)

    sql = """
    SELECT
        id,
        nombre,
        ruta_base,
        fecha_creacion
    FROM proyectos
    ORDER BY fecha_creacion DESC;
    """

    return execute(conn, sql)

end

# =========================================================
# GRUPOS
# =========================================================

function crear_grupo(conn, proyecto_id, nombre)

    sql = """
    INSERT INTO grupos (
        proyecto_id,
        nombre
    )
    VALUES (\$1, \$2)
    RETURNING id;
    """

    result = execute(conn, sql, [
        proyecto_id,
        nombre
    ])

    return first(result)[1]

end

# =========================================================
# OBTENER GRUPOS
# =========================================================

function obtener_grupos(conn, proyecto_id)

    sql = """
    SELECT
        id,
        nombre
    FROM grupos
    WHERE proyecto_id = \$1;
    """

    return execute(conn, sql, [proyecto_id])

end

# =========================================================
# ARCHIVOS
# =========================================================

function crear_archivo(conn, grupo_id, nombre, ruta, tipo)

    sql = """
    INSERT INTO archivos (
        grupo_id,
        nombre,
        ruta,
        tipo
    )
    VALUES (\$1, \$2, \$3, \$4)
    RETURNING id;
    """

    result = execute(conn, sql, [
        grupo_id,
        nombre,
        ruta,
        tipo
    ])

    return first(result)[1]

end

# =========================================================
# OBTENER ARCHIVOS
# =========================================================

function obtener_archivos(conn, grupo_id)

    sql = """
    SELECT
        id,
        nombre,
        ruta,
        tipo
    FROM archivos
    WHERE grupo_id = \$1;
    """

    return execute(conn, sql, [grupo_id])

end

# =========================================================
# RESULTADOS
# =========================================================

function crear_resultado(conn, archivo_id, tipo, descripcion="")

    sql = """
    INSERT INTO resultados (
        archivo_id,
        tipo,
        descripcion
    )
    VALUES (\$1, \$2, \$3)
    RETURNING id;
    """

    result = execute(conn, sql, [
        archivo_id,
        tipo,
        descripcion
    ])

    return first(result)[1]

end

# =========================================================
# FEATURES
# =========================================================

function guardar_feature(conn, resultado_id, nombre, valor, categoria)

    sql = """
    INSERT INTO features (
        resultado_id,
        nombre,
        valor,
        categoria
    )
    VALUES (\$1, \$2, \$3, \$4);
    """

    execute(conn, sql, [
        resultado_id,
        nombre,
        valor,
        categoria
    ])

end

# =========================================================
# OBTENER FEATURES
# =========================================================

function obtener_features(conn, resultado_id)

    sql = """
    SELECT
        id,
        nombre,
        valor,
        categoria
    FROM features
    WHERE resultado_id = \$1;
    """

    return execute(conn, sql, [resultado_id])

end

# =========================================================
# ESTADISTICAS
# =========================================================

function guardar_estadistica(conn, resultado_id, nombre, valor)

    sql = """
    INSERT INTO estadisticas (
        resultado_id,
        nombre,
        valor
    )
    VALUES (\$1, \$2, \$3);
    """

    execute(conn, sql, [
        resultado_id,
        nombre,
        valor
    ])

end

# =========================================================
# MASCARAS
# =========================================================

function guardar_mascara(conn, archivo_id, ruta, tipo)

    sql = """
    INSERT INTO mascaras (
        archivo_id,
        ruta,
        tipo
    )
    VALUES (\$1, \$2, \$3);
    """

    execute(conn, sql, [
        archivo_id,
        ruta,
        tipo
    ])

end

# =========================================================
# ELIMINAR PROYECTO
# =========================================================
# grupos/archivos/resultados/features/estadisticas/mascaras se borran solos
# vía ON DELETE CASCADE (ver database/schema.jl) — acá solo falta borrar la
# carpeta real en disco, y eso lo hace el handler (necesita `ruta_base`,
# que ya se obtuvo antes con `obtener_proyecto`).

function eliminar_proyecto(conn, proyecto_id)

    sql = """
    DELETE FROM proyectos
    WHERE id = \$1;
    """

    execute(conn, sql, [proyecto_id])

end

# =========================================================
# RENOMBRAR PROYECTO
# =========================================================

function renombrar_proyecto(conn, proyecto_id, nuevo_nombre, nueva_ruta_base)

    sql = """
    UPDATE proyectos
    SET nombre = \$2,
        ruta_base = \$3
    WHERE id = \$1;
    """

    execute(conn, sql, [
        proyecto_id,
        nuevo_nombre,
        nueva_ruta_base
    ])

end

# =========================================================
# OBTENER GRUPO POR NOMBRE (dentro de un proyecto)
# =========================================================

function obtener_grupo_por_nombre(conn, proyecto_id, nombre)

    sql = """
    SELECT id, nombre
    FROM grupos
    WHERE proyecto_id = \$1 AND nombre = \$2;
    """

    return collect(execute(conn, sql, [proyecto_id, nombre]))

end

# =========================================================
# RENOMBRAR GRUPO (carpeta)
# =========================================================

function renombrar_grupo(conn, grupo_id, nuevo_nombre)

    sql = """
    UPDATE grupos
    SET nombre = \$2
    WHERE id = \$1;
    """

    execute(conn, sql, [grupo_id, nuevo_nombre])

end

# =========================================================
# ARCHIVOS DE UN PROYECTO COMPLETO (para cascada de renombrado)
# =========================================================

function archivos_bajo_proyecto(conn, proyecto_id)

    sql = """
    SELECT a.id, a.ruta
    FROM archivos a
    JOIN grupos g ON a.grupo_id = g.id
    WHERE g.proyecto_id = \$1;
    """

    return collect(execute(conn, sql, [proyecto_id]))

end

function archivos_bajo_grupo(conn, grupo_id)

    sql = """
    SELECT id, ruta
    FROM archivos
    WHERE grupo_id = \$1;
    """

    return collect(execute(conn, sql, [grupo_id]))

end

function actualizar_ruta_archivo(conn, archivo_id, nueva_ruta)

    sql = """
    UPDATE archivos
    SET ruta = \$2
    WHERE id = \$1;
    """

    execute(conn, sql, [archivo_id, nueva_ruta])

end

"""
    actualizar_rutas_por_prefijo!(conn, filas, prefijo_viejo, prefijo_nuevo)

Cuando se renombra una carpeta (proyecto o grupo) en disco, todas las
rutas absolutas guardadas en `archivos.ruta` bajo esa carpeta quedan
obsoletas (siguen apuntando a la ruta vieja). `filas` es el resultado de
`archivos_bajo_proyecto`/`archivos_bajo_grupo` (cada fila con `[id, ruta]`).
Esta función recalcula la ruta nueva reemplazando el prefijo y actualiza
cada fila — uno por uno, en Julia, para no depender de escapar
correctamente el prefijo viejo como patrón SQL (rutas pueden traer
caracteres especiales de regex en Windows, paréntesis, espacios, etc.).
"""
function actualizar_rutas_por_prefijo!(conn, filas, prefijo_viejo::AbstractString, prefijo_nuevo::AbstractString)
    actualizadas = 0
    for fila in filas
        archivo_id = fila[1]
        ruta_vieja = fila[2]
        if startswith(ruta_vieja, prefijo_viejo)
            ruta_nueva = prefijo_nuevo * ruta_vieja[(length(prefijo_viejo) + 1):end]
            actualizar_ruta_archivo(conn, archivo_id, ruta_nueva)
            actualizadas += 1
        end
    end
    return actualizadas
end

end