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

        # La carpeta de resultados se resuelve ANTES de analizar: el análisis guarda ahí el JSON
        # de cada grafo (nodos y aristas), y después se escribe el Excel resumen en la misma carpeta.
        ruta_resultados = nothing
        try
            ruta_resultados = determinar_ruta_resultados(ruta_proyecto)
        catch e
            println("⚠️  No se pudo preparar la carpeta de resultados: $e")
        end
        dir_salida = isnothing(ruta_resultados) ? nothing : joinpath(ruta_resultados, "grafos")

        result = analizar_grafos(rutas_completas, tipo_grafo, opciones; on_progreso=on_progreso, dir_salida=dir_salida,
                                 registrar_resultado=GrafosCache.registrar!)

        if result["success"] && !isnothing(ruta_resultados)
            try
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

# ------------------------------------------------------------------------
# POST /api/grafos/corte
# body: {resultado_id, orientacion: "axial"|"coronal"|"sagittal", indice (1-indexado),
#        capas?: {mascara, esqueleto, nodos} (default true), grosor?: cortes vecinos a cada
#        lado cuyo esqueleto/nodos se proyectan (default 0)}
# Dibuja un corte del volumen analizado con las capas superpuestas, sin recalcular nada:
# usa lo que dejó el análisis en `GrafosCache`.
# ------------------------------------------------------------------------
function handler_grafos_corte(req, params)
    request_data = leer_body_json(req)
    id = String(get(request_data, "resultado_id", ""))
    orientacion = String(get(request_data, "orientacion", "axial"))
    indice = round(Int, get(request_data, "indice", 1))
    grosor = round(Int, get(request_data, "grosor", 0))
    capas = get(request_data, "capas", Dict())

    if !(orientacion in ("axial", "coronal", "sagittal"))
        return error_response(400, "orientacion inválida: '$orientacion' (esperado axial, coronal o sagittal)")
    end

    datos = GrafosCache.obtener(id)
    if isnothing(datos)
        return error_response(404, "Resultado no disponible (se liberó de memoria): vuelve a ejecutar el análisis de este archivo")
    end

    png, total, idx = renderizar_corte_grafo(datos, orientacion, indice;
        mostrar_mascara=Bool(get(capas, "mascara", true)),
        mostrar_esqueleto=Bool(get(capas, "esqueleto", true)),
        mostrar_nodos=Bool(get(capas, "nodos", true)),
        grosor=grosor)

    return json_response(200, Dict(
        "success" => true,
        "imagen" => png,
        "orientacion" => orientacion,
        "indice" => idx,
        "total_cortes" => total,
    ))
end

registrar_ruta!("POST", "/api/analisis-grafos", handler_analisis_grafos)
registrar_ruta!("POST", "/api/grafos/corte", handler_grafos_corte)
