# ==============================================================================
# Handler: análisis radiómico
# ==============================================================================
#
# El cómputo pesado corre en una tarea propia (`Jobs.lanzar_job!`, que usa
# `Threads.@spawn`) en vez de bloquear el hilo que atiende el request de
# principio a fin. Por defecto el handler igual espera (`Jobs.esperar_job`)
# y responde con el resultado completo — mismo contrato que antes, cero
# cambios necesarios en el frontend — pero esa espera cede el control al
# scheduler (a diferencia de un loop de cómputo puro), así que otros
# requests concurrentes (otro usuario abriendo su proyecto, por ejemplo) no
# quedan en cola detrás de un análisis largo.
#
# Con `"async": true` en el body, el handler responde de inmediato con un
# `job_id` consultable en `GET /api/jobs/:id` — path ya disponible para
# cuando la interfaz quiera mostrar una barra de progreso real en vez de
# esperar a ciegas.

function handler_analisis_radiomico(req, params)
    request_data = leer_body_json(req)

    archivos = String[String(a) for a in get(request_data, "archivos", String[])]
    modo_paralelo = get(request_data, "modo_paralelo", false)
    ruta_proyecto = String(get(request_data, "ruta_proyecto", ""))
    modo_async = get(request_data, "async", false)

    if isempty(archivos)
        return error_response(400, "No se proporcionaron archivos")
    end

    rutas_resueltas = Dict(a => FileResolver.resolver_ruta_archivo(a) for a in archivos)
    faltantes = [a for a in archivos if isnothing(rutas_resueltas[a])]
    if !isempty(faltantes)
        return error_response(404, "Archivos no encontrados: $(join(faltantes, ", "))")
    end
    # Comprehension tipada (`String[...]`): en este punto ya se descartaron
    # los `nothing` arriba, pero el tipo estático de `rutas_resueltas[a]`
    # sigue siendo `Union{String,Nothing}` para el compilador — sin el tipo
    # explícito, `rutas_completas` quedaría como `Vector{Any}`/`Vector{Union{...}}`
    # y `analizar_radiomico(archivos::Vector{String}, ...)` fallaría por
    # firma de método (Julia no relaja tipos de contenedor automáticamente).
    rutas_completas = String[rutas_resueltas[a] for a in archivos]

    println("\n🔬 Iniciando análisis radiómico...")
    println("   Archivos: $(length(rutas_completas))")
    println("   Modo: $(modo_paralelo ? "PARALELO" : "LINEAL")")

    trabajo = function (job)
        on_progreso = (completados, total) -> Jobs.actualizar_progreso!(
            job, completados / total, "Archivo $completados de $total"
        )

        result = analizar_radiomico(rutas_completas, modo_paralelo; on_progreso=on_progreso)

        if result["success"]
            try
                ruta_resultados = determinar_ruta_resultados(ruta_proyecto)
                ruta_excel = guardar_resultados_radiomicos_excel(result, ruta_resultados)
                result["ruta_excel"] = ruta_excel
                println("📊 Excel guardado: $ruta_excel")
            catch e
                println("⚠️  Error guardando Excel: $e")
            end
        end

        Jobs.completar_job!(job, result)
    end

    job = Jobs.lanzar_job!("radiomico", trabajo)

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

registrar_ruta!("POST", "/api/analisis-radiomico", handler_analisis_radiomico)
