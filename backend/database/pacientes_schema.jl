# ==============================================================================
# SchemaPacientes — tablas del repositorio histórico de pacientes
# ==============================================================================
#
# Jerarquía clínica: pacientes -> estudios -> archivos_medicos.
# Es independiente de `proyectos`/`grupos`/`archivos` (ver database/schema.jl):
# no hay llaves foráneas entre ambas jerarquías.
#
# Igual que `Schema.crear_tablas`, es idempotente: `IF NOT EXISTS` hace que se
# pueda ejecutar en cada arranque del servidor sin error ni pérdida de datos.
# OJO: `CREATE TABLE IF NOT EXISTS` NO altera una tabla que ya existe. Este es
# el esquema definitivo de la Fase 2; si las tablas de la Fase 1 siguen
# creadas, hay que borrarlas (están vacías) para que se creen con estas
# columnas. Cambios futuros requerirán `ALTER TABLE ... IF NOT EXISTS`.
#
# FECHAS EN UTC: las columnas son `TIMESTAMP` (sin zona horaria). Para que el
# valor guardado sea siempre UTC —sin importar la zona horaria configurada en
# el servidor PostgreSQL— el DEFAULT es `NOW() AT TIME ZONE 'UTC'` y no
# `NOW()` a secas. Así las queries pueden devolverlas con `Z` final sin mentir.
# ==============================================================================

module SchemaPacientes

using LibPQ

export crear_tablas_pacientes

"""
    crear_tablas_pacientes(conn)

Crea (si no existen) las tablas `pacientes`, `estudios` y `archivos_medicos`
y sus índices. Se llama una vez desde `server.jl` justo después de
`Schema.crear_tablas(DB_CONN)`.
"""
function crear_tablas_pacientes(conn)

    # =========================
    # TABLA PACIENTES
    # =========================
    # `codigo_paciente` es NOT NULL; su unicidad la garantiza el índice
    # `uq_pacientes_codigo_lower` (más abajo), que ignora mayúsculas.

    execute(conn, """
    CREATE TABLE IF NOT EXISTS pacientes (
        id_paciente SERIAL PRIMARY KEY,
        codigo_paciente VARCHAR(255) NOT NULL,
        nombre VARCHAR(255),
        datos_clinicos JSONB,
        notas TEXT,
        fecha_creacion TIMESTAMP NOT NULL DEFAULT (NOW() AT TIME ZONE 'UTC'),
        fecha_actualizacion TIMESTAMP NOT NULL DEFAULT (NOW() AT TIME ZONE 'UTC')
    );
    """)

    # =========================
    # TABLA ESTUDIOS
    # =========================

    execute(conn, """
    CREATE TABLE IF NOT EXISTS estudios (
        id_estudio SERIAL PRIMARY KEY,
        id_paciente INTEGER NOT NULL
            REFERENCES pacientes(id_paciente) ON DELETE CASCADE,
        modalidad VARCHAR(255),
        fecha_estudio TIMESTAMP,
        descripcion TEXT,
        fecha_creacion TIMESTAMP NOT NULL DEFAULT (NOW() AT TIME ZONE 'UTC'),
        fecha_actualizacion TIMESTAMP NOT NULL DEFAULT (NOW() AT TIME ZONE 'UTC')
    );
    """)

    # =========================
    # TABLA ARCHIVOS_MEDICOS
    # =========================
    # Solo se guarda la RUTA del archivo, nunca el contenido binario.
    # `ruta_relativa` es relativa a PROJECTS_DIR y usa siempre `/` como
    # separador (ej. "_pacientes/paciente_1/estudio_3/t1.nii.gz"), para que la
    # BD siga siendo válida si se mueve el volumen o se cambia de SO.
    # `tipo_archivo`: "imagen", "mascara_roi", "radiomica", "estadistica",
    #                 "visualizacion", "reporte" (se valida en el handler).

    execute(conn, """
    CREATE TABLE IF NOT EXISTS archivos_medicos (
        id_archivo SERIAL PRIMARY KEY,
        id_estudio INTEGER NOT NULL
            REFERENCES estudios(id_estudio) ON DELETE CASCADE,
        tipo_archivo VARCHAR(255) NOT NULL,
        formato VARCHAR(255),
        nombre_original VARCHAR(255) NOT NULL,
        ruta_relativa TEXT NOT NULL,
        tamano_bytes BIGINT NOT NULL DEFAULT 0,
        metadatos_extra JSONB,
        fecha_subida TIMESTAMP NOT NULL DEFAULT (NOW() AT TIME ZONE 'UTC'),
        fecha_actualizacion TIMESTAMP NOT NULL DEFAULT (NOW() AT TIME ZONE 'UTC')
    );
    """)

    # =========================
    # ÍNDICES
    # =========================
    # PostgreSQL NO crea índices automáticamente en columnas FOREIGN KEY
    # (sí en PRIMARY KEY y UNIQUE). Sin ellos, "estudios de un paciente" o
    # el borrado en cascada recorrerían la tabla completa.

    # Índice único sobre una EXPRESIÓN: `lower(...)` hace que "PAC-1" y
    # "pac-1" choquen (SQLSTATE 23505), cosa que un UNIQUE normal no detecta.
    execute(conn, """
    CREATE UNIQUE INDEX IF NOT EXISTS uq_pacientes_codigo_lower
    ON pacientes (lower(codigo_paciente));
    """)

    # Mismo orden que usa `listar_pacientes`; el `id` desempata pacientes
    # creados en el mismo instante para que la paginación sea estable.
    execute(conn, """
    CREATE INDEX IF NOT EXISTS idx_pacientes_orden
    ON pacientes (fecha_creacion DESC, id_paciente DESC);
    """)

    # Índice compuesto: sirve para filtrar por `id_paciente` (FK y cascada)
    # Y para devolver sus estudios ya ordenados sin un paso extra de ORDER BY.
    execute(conn, """
    CREATE INDEX IF NOT EXISTS idx_estudios_paciente_fecha
    ON estudios (id_paciente, fecha_estudio DESC, id_estudio DESC);
    """)

    execute(conn, """
    CREATE INDEX IF NOT EXISTS idx_archivos_medicos_estudio
    ON archivos_medicos (id_estudio);
    """)

    # Una ruta en disco = un solo registro. El handler de subida se apoya en
    # este índice para detectar colisiones de forma atómica (sin TOCTOU).
    execute(conn, """
    CREATE UNIQUE INDEX IF NOT EXISTS uq_archivos_ruta_relativa
    ON archivos_medicos (ruta_relativa);
    """)

    println("Tablas de pacientes verificadas correctamente.")

end

end
