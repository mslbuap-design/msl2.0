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
# OJO: `CREATE TABLE IF NOT EXISTS` NO altera una tabla que ya existe; si en el
# futuro se agrega una columna, hará falta un `ALTER TABLE ... ADD COLUMN IF
# NOT EXISTS` explícito.
# ==============================================================================

module SchemaPacientes

using LibPQ

export crear_tablas_pacientes

"""
    crear_tablas_pacientes(conn)

Crea (si no existen) las tablas `pacientes`, `estudios` y `archivos_medicos`
y los índices sobre sus llaves foráneas. Se llama una vez desde `server.jl`
justo después de `Schema.crear_tablas(DB_CONN)`.
"""
function crear_tablas_pacientes(conn)

    # =========================
    # TABLA PACIENTES
    # =========================
    # `codigo_paciente` es NOT NULL UNIQUE: UNIQUE solo no basta porque
    # PostgreSQL permite varios NULL en una columna UNIQUE. Además se usa
    # como nombre de carpeta en disco (Bloque 3).

    execute(conn, """
    CREATE TABLE IF NOT EXISTS pacientes (
        id_paciente SERIAL PRIMARY KEY,
        codigo_paciente VARCHAR(255) NOT NULL UNIQUE,
        nombre VARCHAR(255),
        datos_clinicos JSONB,
        notas TEXT,
        fecha_creacion TIMESTAMP DEFAULT NOW()
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
        fecha_creacion TIMESTAMP DEFAULT NOW()
    );
    """)

    # =========================
    # TABLA ARCHIVOS_MEDICOS
    # =========================
    # Solo se guarda la RUTA del archivo (vive en PROJECTS_DIR/_pacientes/...),
    # nunca el contenido binario.
    # `tipo_archivo`: "imagen", "mascara_roi", "radiomica", "estadistica",
    #                 "visualizacion", "reporte" (se valida en el handler).

    execute(conn, """
    CREATE TABLE IF NOT EXISTS archivos_medicos (
        id_archivo SERIAL PRIMARY KEY,
        id_estudio INTEGER NOT NULL
            REFERENCES estudios(id_estudio) ON DELETE CASCADE,
        tipo_archivo VARCHAR(255) NOT NULL,
        formato VARCHAR(255),
        nombre_original VARCHAR(255),
        ruta_absoluta TEXT NOT NULL,
        metadatos_extra JSONB,
        fecha_subida TIMESTAMP DEFAULT NOW()
    );
    """)

    # =========================
    # ÍNDICES (llaves foráneas)
    # =========================
    # PostgreSQL NO crea índices automáticamente en columnas FOREIGN KEY
    # (sí en PRIMARY KEY y UNIQUE). Sin ellos, "estudios de un paciente" o
    # el borrado en cascada recorrerían la tabla completa.

    execute(conn, """
    CREATE INDEX IF NOT EXISTS idx_estudios_paciente
    ON estudios(id_paciente);
    """)

    execute(conn, """
    CREATE INDEX IF NOT EXISTS idx_archivos_medicos_estudio
    ON archivos_medicos(id_estudio);
    """)

    println("Tablas de pacientes verificadas correctamente.")

end

end
