# ==============================================================================
# Handlers de proyectos
# ==============================================================================

"""
Valida que un nombre de carpeta/proyecto nuevo sea un nombre simple (sin
separadores de ruta ni referencias a directorio padre) — evita que un
`nuevo_nombre` como "../../etc" termine escribiendo fuera del proyecto.
"""
function _nombre_simple_valido(nombre::AbstractString)
    return !isempty(nombre) &&
           !occursin('/', nombre) &&
           !occursin('\\', nombre) &&
           nombre != "." &&
           nombre != ".."
end

# ------------------------------------------------------------------------
# GET /api/proyectos
# ------------------------------------------------------------------------
function handler_listar_proyectos(req, params)
    try
        proyectos = Queries.listar_proyectos(DB_CONN)
        response_data = [
            Dict(
                "id" => p[1],
                "nombre" => p[2],
                "ruta_base" => p[3],
                "fecha_creacion" => string(p[4])
            )
            for p in proyectos
        ]
        return json_response(200, response_data)
    catch e
        println("❌ Error listando proyectos: ", e)
        return error_response(500, string(e))
    end
end

# ------------------------------------------------------------------------
# GET /api/proyecto/:id — abrir proyecto persistente
# ------------------------------------------------------------------------
function handler_abrir_proyecto(req, params)
    proyecto_id = parse_int_seguro(params["id"])
    isnothing(proyecto_id) && return error_response(400, "id de proyecto inválido")

    try
        proyecto_data = Queries.obtener_proyecto(DB_CONN, proyecto_id)
        if isempty(proyecto_data)
            return error_response(404, "Proyecto no encontrado")
        end

        proyecto = proyecto_data[1]
        ruta_proyecto = proyecto[3]
        nombre_proyecto = proyecto[2]

        if !isdir(ruta_proyecto)
            return error_response(404, "La carpeta del proyecto no existe"; extra=Dict("ruta" => ruta_proyecto))
        end

        estructura = escanear_directorio_recursivo(ruta_proyecto)

        return json_response(200, Dict(
            "success" => true,
            "id" => proyecto[1],
            "nombre" => nombre_proyecto,
            "ruta_proyecto" => ruta_proyecto,
            "fecha_creacion" => string(proyecto[4]),
            "estructura" => estructura,
            "num_archivos" => contar_archivos(estructura),
            "num_carpetas" => contar_carpetas(estructura)
        ))
    catch e
        println("❌ Error abriendo proyecto: ", e)
        return error_response(500, string(e))
    end
end

# ------------------------------------------------------------------------
# DELETE /api/proyecto/:id
# ------------------------------------------------------------------------
function handler_eliminar_proyecto(req, params)
    proyecto_id = parse_int_seguro(params["id"])
    isnothing(proyecto_id) && return error_response(400, "id de proyecto inválido")

    try
        proyecto_data = Queries.obtener_proyecto(DB_CONN, proyecto_id)
        if isempty(proyecto_data)
            return error_response(404, "Proyecto no encontrado")
        end
        ruta_proyecto = proyecto_data[1][3]

        # Primero la fila en BD (cascada a grupos/archivos/resultados/...).
        Queries.eliminar_proyecto(DB_CONN, proyecto_id)

        # Luego la carpeta real en disco. Si esto falla (permisos, carpeta ya
        # movida a mano, etc.) el proyecto igual queda borrado de la BD —
        # se informa la falla parcial en vez de revertir todo.
        carpeta_borrada = false
        try
            if isdir(ruta_proyecto)
                rm(ruta_proyecto, recursive=true, force=true)
                carpeta_borrada = true
            end
        catch e
            println("⚠️  Proyecto borrado de la BD pero no se pudo borrar la carpeta: $e")
        end

        return json_response(200, Dict(
            "success" => true,
            "id" => proyecto_id,
            "carpeta_borrada" => carpeta_borrada,
            "message" => "Proyecto eliminado"
        ))
    catch e
        println("❌ Error eliminando proyecto: ", e)
        return error_response(500, string(e))
    end
end

# ------------------------------------------------------------------------
# PUT /api/proyecto/:id/renombrar — body: {nuevo_nombre}
# ------------------------------------------------------------------------
function handler_renombrar_proyecto(req, params)
    proyecto_id = parse_int_seguro(params["id"])
    isnothing(proyecto_id) && return error_response(400, "id de proyecto inválido")

    request_data = leer_body_json(req)
    nuevo_nombre = String(get(request_data, "nuevo_nombre", ""))

    if !_nombre_simple_valido(nuevo_nombre)
        return error_response(400, "nuevo_nombre inválido")
    end

    try
        proyecto_data = Queries.obtener_proyecto(DB_CONN, proyecto_id)
        if isempty(proyecto_data)
            return error_response(404, "Proyecto no encontrado")
        end
        proyecto = proyecto_data[1]
        ruta_vieja = proyecto[3]

        if !isdir(ruta_vieja)
            return error_response(404, "La carpeta del proyecto no existe en disco"; extra=Dict("ruta" => ruta_vieja))
        end

        ruta_nueva = joinpath(dirname(ruta_vieja), nuevo_nombre)

        if ruta_nueva != ruta_vieja && isdir(ruta_nueva)
            return error_response(409, "Ya existe una carpeta con ese nombre")
        end

        if ruta_nueva != ruta_vieja
            mv(ruta_vieja, ruta_nueva)
        end

        Queries.renombrar_proyecto(DB_CONN, proyecto_id, nuevo_nombre, ruta_nueva)

        # Cascada: las rutas de archivos guardadas en BD siguen apuntando al
        # prefijo viejo — sin esto, abrir el proyecto después de renombrarlo
        # dejaría `analisis-radiomico`/`analisis-estadistico` sin poder
        # encontrar los archivos ya registrados.
        if ruta_nueva != ruta_vieja
            filas = Queries.archivos_bajo_proyecto(DB_CONN, proyecto_id)
            Queries.actualizar_rutas_por_prefijo!(DB_CONN, filas, ruta_vieja, ruta_nueva)
        end

        estructura = escanear_directorio_recursivo(ruta_nueva)

        return json_response(200, Dict(
            "success" => true,
            "id" => proyecto_id,
            "nombre" => nuevo_nombre,
            "ruta_proyecto" => ruta_nueva,
            "estructura" => estructura
        ))
    catch e
        println("❌ Error renombrando proyecto: ", e)
        return error_response(500, string(e))
    end
end

# ------------------------------------------------------------------------
# PUT /api/proyecto/:id/carpeta — body: {carpeta_actual, nuevo_nombre}
# ------------------------------------------------------------------------
function handler_renombrar_carpeta(req, params)
    proyecto_id = parse_int_seguro(params["id"])
    isnothing(proyecto_id) && return error_response(400, "id de proyecto inválido")

    request_data = leer_body_json(req)
    carpeta_actual = String(get(request_data, "carpeta_actual", ""))
    nuevo_nombre = String(get(request_data, "nuevo_nombre", ""))

    if isempty(carpeta_actual) || !_nombre_simple_valido(nuevo_nombre)
        return error_response(400, "carpeta_actual/nuevo_nombre inválidos")
    end

    try
        proyecto_data = Queries.obtener_proyecto(DB_CONN, proyecto_id)
        if isempty(proyecto_data)
            return error_response(404, "Proyecto no encontrado")
        end
        ruta_proyecto = proyecto_data[1][3]

        ruta_vieja = joinpath(ruta_proyecto, carpeta_actual)
        if !isdir(ruta_vieja)
            return error_response(404, "La carpeta no existe: $carpeta_actual")
        end

        ruta_nueva = joinpath(dirname(ruta_vieja), nuevo_nombre)

        if ruta_nueva != ruta_vieja && isdir(ruta_nueva)
            return error_response(409, "Ya existe una carpeta con ese nombre")
        end

        if ruta_nueva != ruta_vieja
            mv(ruta_vieja, ruta_nueva)
        end

        # Si la carpeta corresponde a un "grupo" registrado en BD, mantener
        # nombre y rutas de sus archivos sincronizados. Si es una carpeta
        # que el usuario creó a mano (no está en la tabla `grupos`), el
        # rename en disco ya alcanza — no hay nada más que actualizar.
        nombre_grupo_viejo = basename(carpeta_actual)
        grupos_encontrados = Queries.obtener_grupo_por_nombre(DB_CONN, proyecto_id, nombre_grupo_viejo)
        if !isempty(grupos_encontrados) && ruta_nueva != ruta_vieja
            grupo_id = grupos_encontrados[1][1]
            Queries.renombrar_grupo(DB_CONN, grupo_id, nuevo_nombre)
            filas = Queries.archivos_bajo_grupo(DB_CONN, grupo_id)
            Queries.actualizar_rutas_por_prefijo!(DB_CONN, filas, ruta_vieja, ruta_nueva)
        end

        estructura = escanear_directorio_recursivo(ruta_proyecto)

        return json_response(200, Dict(
            "success" => true,
            "estructura" => estructura
        ))
    catch e
        println("❌ Error renombrando carpeta: ", e)
        return error_response(500, string(e))
    end
end

# ------------------------------------------------------------------------
# POST /api/crear-proyecto
# ------------------------------------------------------------------------
function handler_crear_proyecto(req, params)
    request_data = leer_body_json(req)

    nombre_proyecto = String(get(request_data, "nombre_proyecto", "Nuevo_Proyecto"))
    num_grupos = get(request_data, "num_grupos", 0)
    nombres_grupos = get(request_data, "nombres_grupos", String[])

    # Ruta persistente dentro del volumen de Docker. Antes esto estaba
    # hardcodeado a "/root/projects" ignorando la variable de entorno
    # MSL_PROJECTS_DIR que docker-compose.yml ya define — ahora sí se lee.
    ruta_base = PROJECTS_DIR
    mkpath(ruta_base)

    ruta_proyecto = joinpath(ruta_base, nombre_proyecto)

    if isdir(ruta_proyecto)
        return error_response(400, "El proyecto ya existe en esa ubicación")
    end

    try
        mkpath(ruta_proyecto)
        println("Proyecto creado: $ruta_proyecto")

        proyecto_id = Queries.crear_proyecto(DB_CONN, nombre_proyecto, ruta_proyecto)
        println("📦 Proyecto registrado en PostgreSQL con ID: $proyecto_id")

        carpetas_creadas = String[]
        if num_grupos > 0
            for i in 1:num_grupos
                nombre_grupo = if !isempty(nombres_grupos) && i <= length(nombres_grupos)
                    nombres_grupos[i]
                else
                    "Grupo_$i"
                end

                ruta_grupo = joinpath(ruta_proyecto, nombre_grupo)
                mkpath(ruta_grupo)
                Queries.crear_grupo(DB_CONN, proyecto_id, nombre_grupo)
                push!(carpetas_creadas, nombre_grupo)
                println("  Grupo creado: $nombre_grupo")
            end
        end

        ruta_resultados = determinar_ruta_resultados(ruta_proyecto, nombre_proyecto)
        println(" Carpeta de resultados: $ruta_resultados")

        estructura = escanear_directorio_recursivo(ruta_proyecto)

        return json_response(200, Dict(
            "success" => true,
            "id" => proyecto_id,
            "ruta_proyecto" => ruta_proyecto,
            "ruta_resultados" => ruta_resultados,
            "carpetas_creadas" => carpetas_creadas,
            "estructura" => estructura,
            "message" => "Proyecto creado exitosamente"
        ))
    catch e
        println("❌ Error creando proyecto: $e")
        return error_response(400, string(e))
    end
end

# ------------------------------------------------------------------------
# POST /api/agregar-grupos
# ------------------------------------------------------------------------
function handler_agregar_grupos(req, params)
    request_data = leer_body_json(req)

    ruta_proyecto = String(get(request_data, "ruta_proyecto", ""))
    num_grupos = get(request_data, "num_grupos", 1)
    prefijo = String(get(request_data, "prefijo", "Grupo"))

    if isempty(ruta_proyecto) || !isdir(ruta_proyecto)
        return error_response(400, "Ruta de proyecto inválida")
    end

    try
        grupos_existentes = filter(isdir,
            [joinpath(ruta_proyecto, item) for item in readdir(ruta_proyecto)])
        num_actual = length(grupos_existentes)

        carpetas_creadas = String[]
        for i in 1:num_grupos
            nombre_grupo = "$(prefijo)_$(num_actual + i)"
            ruta_grupo = joinpath(ruta_proyecto, nombre_grupo)
            mkpath(ruta_grupo)
            push!(carpetas_creadas, nombre_grupo)
            println("  Grupo agregado: $nombre_grupo")
        end

        estructura = escanear_directorio_recursivo(ruta_proyecto)

        println("✅ $(length(carpetas_creadas)) grupos agregados")

        return json_response(200, Dict(
            "success" => true,
            "carpetas_creadas" => carpetas_creadas,
            "estructura" => estructura
        ))
    catch e
        println("❌ Error agregando grupos: $e")
        return error_response(400, string(e))
    end
end

# ------------------------------------------------------------------------
# POST /api/seleccionar-carpeta-local
# ------------------------------------------------------------------------
function handler_seleccionar_carpeta_local(req, params)
    if !NATIVE_FILE_DIALOG_AVAILABLE
        return json_response(501, Dict(
            "success" => false,
            "error" => "NativeFileDialog no disponible",
            "usar_fallback" => true
        ))
    end

    try
        folder_path = pick_folder()

        if !isnothing(folder_path) && isdir(folder_path)
            nombre_proyecto = basename(folder_path)
            println("Proyecto seleccionado: $folder_path")

            estructura = escanear_directorio_recursivo(folder_path)
            num_archivos = contar_archivos(estructura)
            num_carpetas = contar_carpetas(estructura)

            println("✅ Estructura escaneada: $num_archivos archivos, $num_carpetas carpetas")

            return json_response(200, Dict(
                "success" => true,
                "ruta_proyecto" => folder_path,
                "nombre_proyecto" => nombre_proyecto,
                "estructura" => estructura,
                "num_archivos" => num_archivos,
                "num_carpetas" => num_carpetas,
                "metodo" => "local"
            ))
        else
            return json_response(500, Dict("success" => false, "error" => "Selección cancelada"))
        end
    catch e
        println("❌ Error en pick_folder: $e")
        return json_response(500, Dict(
            "success" => false,
            "error" => "Error abriendo selector: $(string(e))",
            "usar_fallback" => true
        ))
    end
end

registrar_ruta!("GET", "/api/proyectos", handler_listar_proyectos)
registrar_ruta!("GET", "/api/proyecto/:id", handler_abrir_proyecto)
registrar_ruta!("DELETE", "/api/proyecto/:id", handler_eliminar_proyecto)
registrar_ruta!("PUT", "/api/proyecto/:id/renombrar", handler_renombrar_proyecto)
registrar_ruta!("PUT", "/api/proyecto/:id/carpeta", handler_renombrar_carpeta)
registrar_ruta!("POST", "/api/crear-proyecto", handler_crear_proyecto)
registrar_ruta!("POST", "/api/agregar-grupos", handler_agregar_grupos)
registrar_ruta!("POST", "/api/seleccionar-carpeta-local", handler_seleccionar_carpeta_local)
