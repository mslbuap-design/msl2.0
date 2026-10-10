# ==============================================================================
# Handler: análisis por grafos (4º módulo)
# ==============================================================================
# Mismo patrón que `radiomica.jl`/`estadistica.jl`: el cómputo corre en una
# tarea propia vía `Jobs`, el handler espera de forma no bloqueante por
# defecto (compatible con el frontend actual) y responde de inmediato con
# `job_id` si el body trae `"async": true`.
#
# `tipo_grafo` decide la rama: "vascular" (Fase 0: placeholder, ver
# AnalisisGrafos.jl) o "conectividad" (reservado). Este último se rechaza
# ACÁ, antes de crear el job — es un rechazo instantáneo y conocido (falta
# soporte de lectura 4D), no algo que valga la pena correr en una tarea
# aparte.

function handler_analisis_grafos(req, params)
    request_data = leer_body_json(req)

    archivos = String[String(a) for a in get(request_data, "archivos", String[])]
    tipo_grafo = String(get(request_data, "tipo_grafo", "vascular"))
    opciones = get(request_data, "opciones", Dict())
    ruta_proyecto = String(get(request_data, "ruta_proyecto", ""))
    modo_async = get(request_data, "async", false)

    if isempty(archivos)
        return error_response(400, "No se proporcionaron archivos")
    end

    if tipo_grafo == "conectividad"
        return json_response(501, Dict(
            "success" => false,
            "error" => "Grafos de conectividad (series temporales) todavía no está implementado.",
        ))
    elseif tipo_grafo != "vascular"
        return error_response(400, "tipo_grafo desconocido: '$tipo_grafo' (esperado 'vascular' o 'conectividad')")
    end

    rutas_resueltas = Dict(a => FileResolver.resolver_ruta_archivo(a) for a in archivos)
    faltantes = [a for a in archivos if isnothing(rutas_resueltas[a])]
    if !isempty(faltantes)
        return error_response(404, "Archivos no encontrados: $(join(faltantes, ", "))")
    end
    rutas_completas = String[rutas_resueltas[a] for a in archivos]

    println("\n🕸️  Iniciando análisis por grafos ($tipo_grafo)...")
    println("   Archivos: $(length(rutas_completas))")

    trabajo = function (job)
        on_progreso = (completados, total) -> Jobs.actualizar_progreso!(
            job, completados / total, "Archivo $completados de $total"
        )

        result = analizar_grafos(rutas_completas, tipo_grafo, opciones; on_progreso=on_progreso)

        if result["success"]
            try
                ruta_resultados = determinar_ruta_resultados(ruta_proyecto)
                ruta_excel = guardar_resultados_grafos_excel(result, ruta_resultados)
                result["ruta_excel"] = ruta_excel
            catch e
                println("⚠️  Error guardando Excel: $e")
            end
        end

        Jobs.completar_job!(job, result)
    end

    job = Jobs.lanzar_job!("grafos", trabajo)

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

registrar_ruta!("POST", "/api/analisis-grafos", handler_analisis_grafos)
