# ==============================================================================
# Handlers de archivos
# ==============================================================================

# ------------------------------------------------------------------------
# POST /api/agregar-archivos
# ------------------------------------------------------------------------
function handler_agregar_archivos(req, params)
    request_data = leer_body_json(req)

    ruta_proyecto = String(get(request_data, "ruta_proyecto", ""))
    carpeta_destino = String(get(request_data, "carpeta_destino", ""))
    nombre_base = String(get(request_data, "nombre_base", "Archivo"))
    archivos = get(request_data, "archivos", [])

    if isempty(ruta_proyecto) || !isdir(ruta_proyecto)
        return error_response(400, "Ruta de proyecto inválida")
    end

    ruta_carpeta_destino = joinpath(ruta_proyecto, carpeta_destino)

    if !isdir(ruta_carpeta_destino)
        return error_response(400, "Carpeta destino no existe: $carpeta_destino")
    end

    try
        # A qué proyecto/grupo pertenece esto en la BD — por ruta, no por
        # "el último proyecto abierto" (ver nota en `determinar_ruta_resultados`).
        proyecto_rows = Queries.obtener_proyecto_por_ruta(DB_CONN, ruta_proyecto)
        proyecto_id = isempty(proyecto_rows) ? nothing : proyecto_rows[1][1]
        nombre_grupo = basename(ruta_carpeta_destino)

        grupo_id = nothing
        if !isnothing(proyecto_id)
            grupos = Queries.obtener_grupos(DB_CONN, proyecto_id)
            for g in grupos
                if g[2] == nombre_grupo
                    grupo_id = g[1]
                    break
                end
            end
        end

        archivos_agregados = String[]

        for (idx, archivo_info) in enumerate(archivos)
            data_base64 = get(archivo_info, "data", "")
            extension = get(archivo_info, "extension", "dat")

            file_data = base64decode(data_base64)

            nombre_archivo = "$(nombre_base)_$(idx).$(extension)"
            ruta_completa = joinpath(ruta_carpeta_destino, nombre_archivo)

            write(ruta_completa, file_data)

            if !isnothing(grupo_id)
                try
                    Queries.crear_archivo(DB_CONN, grupo_id, nombre_archivo, ruta_completa, extension)
                    println("  🗄️ Archivo registrado en PostgreSQL")
                catch e
                    println("  ⚠️ Error registrando archivo en DB: $e")
                end
            else
                println("  ⚠️ Grupo/proyecto no encontrado en DB (¿$nombre_grupo bajo $ruta_proyecto?) — archivo guardado en disco pero no registrado")
            end

            push!(archivos_agregados, nombre_archivo)
            println("  📄 Archivo copiado: $nombre_archivo")
        end

        estructura = escanear_directorio_recursivo(ruta_proyecto)

        println("✅ $(length(archivos_agregados)) archivos agregados a $carpeta_destino")

        return json_response(200, Dict(
            "success" => true,
            "archivos_agregados" => archivos_agregados,
            "estructura" => estructura,
            "message" => "$(length(archivos_agregados)) archivo(s) agregado(s)"
        ))
    catch e
        println("❌ Error agregando archivos: $e")
        return error_response(500, string(e))
    end
end

# ------------------------------------------------------------------------
# POST /api/upload-file
# ------------------------------------------------------------------------
function handler_upload_file(req, params)
    request_data = leer_body_json(req)

    filename = String(get(request_data, "filename", ""))
    file_data_base64 = String(get(request_data, "data", ""))

    if isempty(filename) || isempty(file_data_base64)
        return error_response(400, "Faltan parámetros: filename y data")
    end

    result = guardar_archivo_temporal(filename, file_data_base64)
    return json_response(result["success"] ? 200 : 500, result)
end

# ------------------------------------------------------------------------
# POST /api/check-file
# ------------------------------------------------------------------------
function handler_check_file(req, params)
    request_data = leer_body_json(req)
    filename = String(get(request_data, "filename", ""))
    compatible = is_compatible_file(filename)

    return json_response(200, Dict(
        "filename" => filename,
        "compatible" => compatible,
        "type" => compatible ? "medical" : "unsupported"
    ))
end

# ------------------------------------------------------------------------
# DELETE /api/limpiar-cache
# ------------------------------------------------------------------------
function handler_limpiar_cache(req, params)
    try
        result = limpiar_cache()
        ImagenesCache.limpiar_imagenes!()
        GrafosCache.limpiar_grafos!()
        result["loaded_images_cleared"] = true
        return json_response(200, result)
    catch e
        println("❌ Error limpiar-cache: ", e)
        return error_response(500, string(e))
    end
end

registrar_ruta!("POST", "/api/agregar-archivos", handler_agregar_archivos)
registrar_ruta!("POST", "/api/upload-file", handler_upload_file)
registrar_ruta!("POST", "/api/check-file", handler_check_file)
registrar_ruta!("DELETE", "/api/limpiar-cache", handler_limpiar_cache)
