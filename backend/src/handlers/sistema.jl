# ==============================================================================
# Handlers de sistema: /api/test, /api/info, /api/cambiar-modo, /api/jobs/:id
# ==============================================================================
#
# Cada handler es una función normal `(req, params) -> HTTP.Response`,
# registrada una vez en `Router` acá abajo. Nada de `elseif`: agregar un
# endpoint es agregar una función + una línea de `registrar_ruta!`.

function handler_test(req, params)
    data = Dict(
        "status" => "ok",
        "message" => "Servidor funcionando correctamente",
        "timestamp" => string(now())
    )
    return json_response(200, data)
end

function handler_info(req, params)
    data = Dict(
        "julia_version" => string(VERSION),
        "threads" => Threads.nthreads(),
        "loaded_images" => ImagenesCache.num_imagenes_cacheadas(),
        "temp_dir" => TEMP_DIR,
        "native_file_dialog" => NATIVE_FILE_DIALOG_AVAILABLE,
        "modo_operacion" => MODO_OPERACION[]
    )
    return json_response(200, data)
end

function handler_cambiar_modo(req, params)
    request_data = leer_body_json(req)
    nuevo_modo = get(request_data, "modo", "julia")

    if nuevo_modo in ["julia", "python"]
        MODO_OPERACION[] = nuevo_modo
        println("🔄 Modo cambiado a: $nuevo_modo")
        return json_response(200, Dict(
            "success" => true,
            "modo_actual" => nuevo_modo,
            "message" => "Modo de operación actualizado"
        ))
    else
        return error_response(400, "Modo inválido. Use 'julia' o 'python'")
    end
end

"""
GET /api/jobs/:id — estado/progreso de un análisis lanzado en modo
asíncrono (o simplemente para consultar avance de uno síncrono en curso
desde otra pestaña/dispositivo). El frontend actual no lo usa todavía
(sigue esperando la respuesta síncrona de siempre), pero ya queda
disponible para cuando se agregue una barra de progreso real.
"""
function handler_job_estado(req, params)
    job = Jobs.obtener_job(params["id"])
    if isnothing(job)
        return error_response(404, "Job no encontrado")
    end

    data = Jobs.job_a_dict(job)
    data["success"] = job.estado != "error"
    if job.estado == "completado"
        data["resultado"] = job.resultado
    end
    return json_response(200, data)
end

registrar_ruta!("GET", "/api/test", handler_test)
registrar_ruta!("GET", "/api/info", handler_info)
registrar_ruta!("POST", "/api/cambiar-modo", handler_cambiar_modo)
registrar_ruta!("GET", "/api/jobs/:id", handler_job_estado)
