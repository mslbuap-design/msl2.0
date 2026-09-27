module Schema

using LibPQ

export crear_tablas

function crear_tablas(conn)

    # =========================
    # TABLA PROYECTOS
    # =========================

    execute(conn, """
    CREATE TABLE IF NOT EXISTS proyectos (
        id SERIAL PRIMARY KEY,
        nombre VARCHAR(255) NOT NULL,
        ruta_base TEXT,
        fecha_creacion TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
    """)

    # =========================
    # TABLA GRUPOS
    # =========================

    execute(conn, """
    CREATE TABLE IF NOT EXISTS grupos (
        id SERIAL PRIMARY KEY,
        proyecto_id INTEGER REFERENCES proyectos(id) ON DELETE CASCADE,
        nombre VARCHAR(255) NOT NULL
    );
    """)

    # =========================
    # TABLA ARCHIVOS
    # =========================

    execute(conn, """
    CREATE TABLE IF NOT EXISTS archivos (
        id SERIAL PRIMARY KEY,
        grupo_id INTEGER REFERENCES grupos(id) ON DELETE CASCADE,
        nombre VARCHAR(255),
        ruta TEXT,
        tipo VARCHAR(100),
        fecha_creacion TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
    """)

    # =========================
    # TABLA RESULTADOS
    # =========================

    execute(conn, """
    CREATE TABLE IF NOT EXISTS resultados (
        id SERIAL PRIMARY KEY,
        archivo_id INTEGER REFERENCES archivos(id) ON DELETE CASCADE,
        tipo VARCHAR(100),
        fecha TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        descripcion TEXT
    );
    """)

    # =========================
    # TABLA FEATURES
    # =========================

    execute(conn, """
    CREATE TABLE IF NOT EXISTS features (
        id SERIAL PRIMARY KEY,
        resultado_id INTEGER REFERENCES resultados(id) ON DELETE CASCADE,
        nombre VARCHAR(255),
        valor DOUBLE PRECISION,
        categoria VARCHAR(100)
    );
    """)

    # =========================
    # TABLA ESTADISTICAS
    # =========================

    execute(conn, """
    CREATE TABLE IF NOT EXISTS estadisticas (
        id SERIAL PRIMARY KEY,
        resultado_id INTEGER REFERENCES resultados(id) ON DELETE CASCADE,
        nombre VARCHAR(255),
        valor DOUBLE PRECISION
    );
    """)

    # =========================
    # TABLA MASCARAS
    # =========================

    execute(conn, """
    CREATE TABLE IF NOT EXISTS mascaras (
        id SERIAL PRIMARY KEY,
        archivo_id INTEGER REFERENCES archivos(id) ON DELETE CASCADE,
        ruta TEXT,
        tipo VARCHAR(100),
        fecha TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
    """)

    # =========================
    # ÍNDICES IMPORTANTES
    # =========================

    execute(conn, """
    CREATE INDEX IF NOT EXISTS idx_grupos_proyecto
    ON grupos(proyecto_id);
    """)

    execute(conn, """
    CREATE INDEX IF NOT EXISTS idx_archivos_grupo
    ON archivos(grupo_id);
    """)

    execute(conn, """
    CREATE INDEX IF NOT EXISTS idx_resultados_archivo
    ON resultados(archivo_id);
    """)

    execute(conn, """
    CREATE INDEX IF NOT EXISTS idx_features_resultado
    ON features(resultado_id);
    """)

    execute(conn, """
    CREATE INDEX IF NOT EXISTS idx_estadisticas_resultado
    ON estadisticas(resultado_id);
    """)

    execute(conn, """
    CREATE INDEX IF NOT EXISTS idx_mascaras_archivo
    ON mascaras(archivo_id);
    """)

    println("Tablas verificadas correctamente.")

end

end