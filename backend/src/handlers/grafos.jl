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
# ------------------------------------------------------------------------
# POST /api/grafos/exportar
# body: {rutas_json: [ruta del grafo_*.json de cada sujeto], formato: "csv"|"xlsx",
#        tabla?: "sujetos"|"aristas"|"nodos" (solo CSV), ruta_proyecto}
# Convierte los datos guardados del análisis en una tabla CSV o en un Excel con una hoja
# por tabla; lo deja en Resultados_<proyecto>/grafos/ y devuelve el contenido en Base64
# para que el navegador lo descargue. Solo lee los grafo_*.json que escribe el análisis.
# ------------------------------------------------------------------------
function handler_grafos_exportar(req, params)
    request_data = leer_body_json(req)
    rutas = String[String(r) for r in get(request_data, "rutas_json", String[])]
    formato = String(get(request_data, "formato", "xlsx"))
    tabla = String(get(request_data, "tabla", "sujetos"))
    ruta_proyecto = String(get(request_data, "ruta_proyecto", ""))
    # Resultado de /api/grafos/comparar (opcional): suma las hojas Comparación / Pares al Excel
    # y permite exportar la comparación sola como CSV (tabla "comparacion" o "pares").
    comparacion = _a_dict(get(request_data, "comparacion", nothing))
    solo_comparacion = formato == "csv" && tabla in ("comparacion", "pares")

    if isempty(rutas) && !solo_comparacion
        return error_response(400, "No hay grafos para exportar: ejecuta primero el análisis")
    end
    if !(formato in ("csv", "xlsx"))
        return error_response(400, "formato inválido: '$formato' (esperado csv o xlsx)")
    end
    if !(tabla in ("sujetos", "aristas", "nodos", "comparacion", "pares"))
        return error_response(400, "tabla inválida: '$tabla' (esperado sujetos, aristas, nodos, comparacion o pares)")
    end
    if solo_comparacion && comparacion === nothing
        return error_response(400, "No hay comparación para exportar: compara los grupos primero")
    end

    try
        ruta_resultados = determinar_ruta_resultados(ruta_proyecto)
        resultado = exportar_grafos(rutas, formato, tabla, joinpath(ruta_resultados, "grafos"); comparacion=comparacion)
        return json_response(200, resultado)
    catch e
        println("❌ Error exportando grafos: ", e)
        return error_response(500, string(e))
    end
end

# ------------------------------------------------------------------------
# POST /api/grafos/comparar
# ------------------------------------------------------------------------
# Comparación estadística entre grupos (Fase 3B), sobre los resultados del análisis
# que el navegador ya tiene: un valor por SUJETO y característica. Síncrono: es rápido
# (54 características × unos pocos grupos). Body:
#   { "sujetos": [{"archivo", "grupo", "caracteristicas": {clave: número|null}}],
#     "grupos": ["Sanos", "Enfermos"]   (REFERENCIA PRIMERO; ≥ 2),
#     "prueba_principal": "no_parametrica" | "parametrica", "alfa": 0.05 }
# Los errores de validación (grupo sin sujetos, el mismo archivo dos veces en un grupo, ...)
# salen como 400 con el motivo; lo demás, 500. La lógica vive en ComparacionGrupos.jl.
# ------------------------------------------------------------------------
function handler_grafos_comparar(req, params)
    request_data = leer_body_json(req)
    sujetos = get(request_data, "sujetos", nothing)
    grupos = String[String(g) for g in get(request_data, "grupos", String[])]
    prueba_principal = String(get(request_data, "prueba_principal", "no_parametrica"))
    alfa = get(request_data, "alfa", 0.05)

    if !(sujetos isa AbstractVector) || isempty(sujetos)
        return error_response(400, "No hay sujetos para comparar: ejecuta primero el análisis")
    end
    if length(grupos) < 2
        return error_response(400, "Selecciona al menos 2 grupos para comparar")
    end
    if !(prueba_principal in ("no_parametrica", "parametrica"))
        return error_response(400, "prueba_principal inválida: '$prueba_principal' (esperado no_parametrica o parametrica)")
    end
    if !(alfa isa Real) || !(0 < alfa < 1)
        return error_response(400, "alfa inválido (esperado un número entre 0 y 1)")
    end

    try
        resultado = comparar_grupos(sujetos, grupos, prueba_principal, Float64(alfa))
        resultado["success"] = true
        return json_response(200, resultado)
    catch e
        println("❌ Error comparando grupos: ", e)
        if e isa ErrorException
            return error_response(400, e.msg)
        end
        return error_response(500, string(e))
    end
end

registrar_ruta!("POST", "/api/grafos/corte", handler_grafos_corte)
registrar_ruta!("POST", "/api/grafos/exportar", handler_grafos_exportar)
registrar_ruta!("POST", "/api/grafos/comparar", handler_grafos_comparar)
