# ==============================================================================
# Handlers de visualización
# ==============================================================================
#
# `filename` acá puede ser, en realidad, la ruta absoluta del archivo
# (`fullPath` del árbol de proyecto) — ver `FileResolver.resolver_ruta_archivo`
# para la prioridad de resolución. El caché de imágenes se indexa por esa
# ruta resuelta, no por el nombre pelado, así que `load-image` y
# `get-slice` sólo coinciden en la misma imagen si de verdad se refieren al
# mismo archivo en disco — ya no hay colisión entre proyectos distintos con
# archivos del mismo nombre.

# ------------------------------------------------------------------------
# POST /api/load-image
# ------------------------------------------------------------------------
function handler_load_image(req, params)
    request_data = leer_body_json(req)
    filename = String(get(request_data, "filename", ""))

    ruta_resuelta = FileResolver.resolver_ruta_archivo(filename)
    if isnothing(ruta_resuelta)
        return error_response(404, "Archivo no encontrado"; extra=Dict("searched_path" => filename))
    end

    img_data = process_medical_image(ruta_resuelta)

    if img_data["success"]
        ImagenesCache.cachear_imagen!(ruta_resuelta, img_data)
        return json_response(200, Dict(
            "success" => true,
            "filename" => filename,
            "type" => img_data["type"],
            "dimensions" => img_data["dimensions"],
            "header" => img_data["header"]
        ))
    else
        return json_response(400, img_data)
    end
end

# ------------------------------------------------------------------------
# POST /api/get-slice
# ------------------------------------------------------------------------
function handler_get_slice(req, params)
    request_data = leer_body_json(req)
    filename = String(get(request_data, "filename", ""))
    orientation = String(get(request_data, "orientation", "axial"))
    slice_num = get(request_data, "slice", 1)

    ruta_resuelta = FileResolver.resolver_ruta_archivo(filename)
    if isnothing(ruta_resuelta)
        return error_response(404, "Imagen no cargada")
    end

    img_data = ImagenesCache.obtener_imagen(ruta_resuelta)
    if isnothing(img_data)
        return error_response(404, "Imagen no cargada")
    end

    data_3d = img_data["data"]
    slice_matrix = extract_slice(data_3d, orientation, slice_num)
    img_base64 = matrix_to_base64_png(slice_matrix)

    return json_response(200, Dict(
        "success" => true,
        "filename" => filename,
        "orientation" => orientation,
        "slice" => slice_num,
        "max_slices" => size(data_3d)[orientation == "sagittal" ? 1 :
                                      orientation == "coronal" ? 2 : 3],
        "image" => img_base64
    ))
end

# ------------------------------------------------------------------------
# POST /api/guardar-imagen — body: {nombre_archivo, imagen_base64, ruta_proyecto?}
# ------------------------------------------------------------------------
function handler_guardar_imagen(req, params)
    request_data = leer_body_json(req)

    nombre_archivo = String(get(request_data, "nombre_archivo", ""))
    imagen_base64 = String(get(request_data, "imagen_base64", ""))
    ruta_proyecto = String(get(request_data, "ruta_proyecto", ""))

    if isempty(nombre_archivo) || isempty(imagen_base64)
        return error_response(400, "Faltan parámetros")
    end

    result = guardar_imagen_resultado(ruta_proyecto, nombre_archivo, imagen_base64)
    return json_response(result["success"] ? 200 : 500, result)
end

registrar_ruta!("POST", "/api/load-image", handler_load_image)
registrar_ruta!("POST", "/api/get-slice", handler_get_slice)
registrar_ruta!("POST", "/api/guardar-imagen", handler_guardar_imagen)
