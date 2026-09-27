# ==============================================================================
# Handler: análisis estadístico
# ==============================================================================
# Mismo patrón que `radiomica.jl`: el análisis corre en una tarea propia vía
# `Jobs`, el handler espera de forma no bloqueante por defecto (compatible
# con el frontend actual) y opcionalmente responde de inmediato con
# `job_id` si el body trae `"async": true`.

function handler_analisis_estadistico(req, params)
    request_data = leer_body_json(req)

    grupos = get(request_data, "grupos", Dict())
    pruebas = get(request_data, "pruebas", String[])
    comparar_por_archivos = get(request_data, "comparar_por_archivos", true)
    tipo_datos = get(request_data, "tipo_datos", "imagenes")
    ruta_proyecto = String(get(request_data, "ruta_proyecto", ""))
    modo_async = get(request_data, "async", false)

    if isempty(grupos) || length(grupos) < 2
        return error_response(400, "Se necesitan al menos 2 grupos para análisis estadístico")
    end

    println("\n📊 Iniciando análisis estadístico...")
    println("   Grupos: $(length(grupos))")
    println("   Pruebas seleccionadas: $(length(pruebas))")
    println("   Tipo de datos: $tipo_datos")

    trabajo = function (job)
        on_progreso = (completadas, total, etapa) -> Jobs.actualizar_progreso!(
            job, total == 0 ? 0.0 : completadas / total, etapa
        )

        result = analizar_estadistico(grupos, pruebas, comparar_por_archivos, tipo_datos; on_progreso=on_progreso)

        if result["success"]
            try
                ruta_resultados = determinar_ruta_resultados(ruta_proyecto)
                ruta_excel = guardar_resultados_estadisticos_excel(result, ruta_resultados)
                result["ruta_excel"] = ruta_excel
                println("📊 Excel guardado: $ruta_excel")
            catch e
                println("⚠️  Error guardando Excel: $e")
            end
        end

        Jobs.completar_job!(job, result)
    end

    job = Jobs.lanzar_job!("estadistico", trabajo)

    if modo_async
        return json_response(202, Dict("success" => true, "job_id" => job.id, "estado" => "corriendo"))
    end

    Jobs.esperar_job(job)

    if job.estado == "error"
        return error_response(500, job.error)
    end

    result = job.resultado
    result["job_id"] = job.id
    return json_response(result["success"] ? 200 : 500, result)
end

registrar_ruta!("POST", "/api/analisis-estadistico", handler_analisis_estadistico)
