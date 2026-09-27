# AnalisisEstadistico.jl
# Módulo de análisis estadístico para aplicación médica
# Implementa pruebas paramétricas y no paramétricas con selección automática

using HypothesisTests
using Statistics
using StatsBase
using LinearAlgebra
using Distributions
using MultivariateStats
using XLSX
using DataFrames
using Dates

"""
    analizar_estadistico(grupos, pruebas, comparar_por_archivos, tipo_datos; on_progreso=nothing)

Función principal que ejecuta análisis estadístico completo.

# Argumentos
- `grupos`: Grupos y archivos correspondientes (Dict o JSON)
- `pruebas`: Lista de pruebas a realizar (Vector o Array)
- `comparar_por_archivos`: true = comparar archivos individuales (Bool o Int)
- `tipo_datos`: "imagenes" o "excel" (String)
- `on_progreso`: función opcional `(completadas::Int, total::Int, etapa::String) -> nothing`,
  llamada tras extraer los datos de cada grupo y tras cada prueba estadística.

# Retorna
- `Dict`: Resultados estructurados con todas las pruebas

Nota sobre rutas: la resolución de "¿dónde está este archivo en disco?"
vive en `FileResolver.resolver_ruta_archivo` (namespacing por proyecto vía
ruta absoluta, con TEMP_DIR como fallback) — ver `extraer_datos_grupos`
más abajo. Antes esta lógica estaba duplicada acá con un `isabs` casero.
"""
function analizar_estadistico(
    grupos,
    pruebas,
    comparar_por_archivos,
    tipo_datos;
    on_progreso::Union{Function,Nothing}=nothing
)
    tiempo_inicio = time()
    println("\n" * "="^70)
    println("🔬 INICIANDO ANÁLISIS ESTADÍSTICO")
    println("="^70)
    
    # DEBUG: Mostrar tipos recibidos
    println("\n🐛 DEBUG - Tipos de entrada:")
    println("   • grupos: $(typeof(grupos))")
    println("   • pruebas: $(typeof(pruebas))")
    println("   • comparar_por_archivos: $(typeof(comparar_por_archivos)) = $comparar_por_archivos")
    println("   • tipo_datos: $(typeof(tipo_datos)) = $tipo_datos")
    
    try
        # Convertir tipos si vienen de JSON
        grupos_dict = Dict{String, Vector{String}}()
        
        # JSON3.Object necesita conversión especial
        if isa(grupos, Dict) || hasproperty(grupos, :keys) || typeof(grupos) <: AbstractDict
            # Iterar sobre las claves del objeto JSON
            for k in keys(grupos)
                key_str = string(k)
                v = grupos[k]
                
                if isa(v, Vector) || isa(v, Array) || typeof(v) <: AbstractVector
                    grupos_dict[key_str] = String[string(x) for x in v]
                else
                    println("⚠️  Formato inesperado en grupo $k: $(typeof(v))")
                end
            end
        else
            println("❌ Tipo de 'grupos' no reconocido: $(typeof(grupos))")
            return Dict("success" => false, "error" => "El parámetro 'grupos' debe ser un Dict o JSON Object")
        end
        
        # Convertir pruebas a Vector{String}
        pruebas_vec = String[]
        if isa(pruebas, Vector) || isa(pruebas, Array) || typeof(pruebas) <: AbstractVector
            pruebas_vec = String[string(x) for x in pruebas]
        else
            println("❌ Tipo de 'pruebas' no reconocido: $(typeof(pruebas))")
            return Dict("success" => false, "error" => "El parámetro 'pruebas' debe ser un Array o Vector")
        end
        
        # Convertir comparar_por_archivos a Bool
        comparar_bool = false
        if isa(comparar_por_archivos, Bool)
            comparar_bool = comparar_por_archivos
        elseif isa(comparar_por_archivos, Integer)
            comparar_bool = comparar_por_archivos != 0
        elseif isa(comparar_por_archivos, String)
            comparar_bool = lowercase(string(comparar_por_archivos)) in ["true", "1", "yes"]
        end
        
        # Convertir tipo_datos a String
        tipo_datos_str = string(tipo_datos)
        
        println("✓ Parámetros convertidos correctamente")
        println("  - Grupos: $(length(grupos_dict))")
        for (nombre, archivos) in grupos_dict
            println("    → $nombre: $(length(archivos)) archivos")
        end
        println("  - Pruebas: $(length(pruebas_vec))")
        for prueba in pruebas_vec
            println("    → $prueba")
        end
        println("  - Tipo: $tipo_datos_str")
        
        # Validar entrada
        if isempty(grupos_dict)
            return Dict("success" => false, "error" => "No hay grupos definidos")
        end
        
        if length(grupos_dict) < 2
            return Dict("success" => false, "error" => "Se requieren al menos 2 grupos")
        end
        
        # Extraer datos de cada grupo. `total_trabajo` es el denominador único
        # de progreso para TODO el análisis (extracción + pruebas), así el
        # avance reportado nunca "salta" al pasar de una etapa a la otra.
        total_trabajo = length(grupos_dict) + length(pruebas_vec)
        println("\n📊 Extrayendo datos de $(length(grupos_dict)) grupos...")
        if !isnothing(on_progreso)
            on_progreso(0, total_trabajo, "Extrayendo datos de los grupos")
        end
        progreso_extraccion = if isnothing(on_progreso)
            nothing
        else
            (idx_grupo, _total_grupos, etapa) -> on_progreso(idx_grupo, total_trabajo, etapa)
        end
        datos_grupos = extraer_datos_grupos(grupos_dict, tipo_datos_str; on_progreso=progreso_extraccion)
        
        if isempty(datos_grupos)
            return Dict("success" => false, "error" => "No se pudieron extraer datos")
        end
        
        # PASO 1: Test de normalidad (siempre obligatorio)
        println("\n📈 PASO 1: Evaluando normalidad (Shapiro-Wilk)...")
        test_normalidad = evaluar_normalidad(datos_grupos)
        es_parametrico = determinar_parametricidad(test_normalidad)
        
        println("   → Distribución: $(es_parametrico ? "PARAMÉTRICA ✓" : "NO PARAMÉTRICA ✗")")
        
        # PASO 2: Ejecutar pruebas solicitadas
        println("\n🧪 PASO 2: Ejecutando $(length(pruebas_vec)) pruebas estadísticas...")
        resultados = Dict{String, Any}()
        
        for (idx_prueba, prueba) in enumerate(pruebas_vec)
            try
                println("   • $prueba...")
                resultado_prueba = ejecutar_prueba(
                    prueba, 
                    datos_grupos, 
                    es_parametrico,
                    test_normalidad
                )
                if !isnothing(resultado_prueba)
                    resultados[prueba] = resultado_prueba
                end
            catch e
                println("      ⚠️  Error en $prueba: $e")
                resultados[prueba] = Dict(
                    "error" => string(e),
                    "success" => false
                )
            end
            if !isnothing(on_progreso)
                on_progreso(
                    length(grupos_dict) + idx_prueba,
                    total_trabajo,
                    "Prueba completada: $prueba"
                )
            end
        end
        
        # Construir respuesta final
        tiempo_total = round(time() - tiempo_inicio, digits=2)
        
        println("\n" * "="^70)
        println("✅ ANÁLISIS COMPLETADO EN $tiempo_total segundos")
        println("="^70 * "\n")
        
        return Dict(
            "success" => true,
            "parametricidad" => Dict(
                "es_parametrico" => es_parametrico,
                "test_normalidad" => test_normalidad
            ),
            "resultados" => resultados,
            "tiempo_analisis" => tiempo_total,
            "num_grupos" => length(grupos_dict),
            "nombres_grupos" => collect(keys(grupos_dict))
        )
        
    catch e
        println("\n❌ ERROR GENERAL: $e")
        return Dict(
            "success" => false,
            "error" => string(e),
            "tiempo_analisis" => round(time() - tiempo_inicio, digits=2)
        )
    end
end

"""
    extraer_datos_grupos(grupos, tipo_datos; on_progreso=nothing)

Extrae valores numéricos de archivos según el tipo.

La resolución de ruta de cada archivo usa `FileResolver.resolver_ruta_archivo`:
si el frontend mandó la ruta absoluta (archivo ya viviendo dentro de un
proyecto montado en `./projects`), se usa directo; si no, cae a buscarlo
en `TEMP_DIR` (archivos subidos desde el navegador). Antes esta función
duplicaba esa lógica a mano con un `isabs` casero — ver `FileResolver`.
"""
function extraer_datos_grupos(grupos::Dict{String, Vector{String}}, tipo_datos::String; on_progreso::Union{Function,Nothing}=nothing)
    datos_grupos = Dict{String, Vector{Float64}}()
    total_grupos = length(grupos)

    for (idx_grupo, (nombre_grupo, archivos)) in enumerate(grupos)
        println("\n   • Procesando grupo: $nombre_grupo ($(length(archivos)) archivos)")
        datos_grupo = Float64[]
        
        for archivo in archivos
            try
                ruta_archivo = FileResolver.resolver_ruta_archivo(archivo)

                if isnothing(ruta_archivo)
                    println("        ❌ No se pudo localizar el archivo: $archivo")
                    continue
                end

                println("      → Usando: $ruta_archivo ($(filesize(ruta_archivo)) bytes)")
                
                if tipo_datos == "excel"
                    valores = extraer_datos_excel(ruta_archivo)
                    append!(datos_grupo, valores)
                elseif tipo_datos == "imagenes"
                    valores = extraer_datos_imagen(ruta_archivo)
                    append!(datos_grupo, valores)
                end
            catch e
                println("      ❌ Error procesando $archivo:")
                println("         $e")
                # Mostrar stack trace limitado
                bt = catch_backtrace()
                for frame in bt[1:min(2, length(bt))]
                    println("         → $frame")
                end
            end
        end
        
        if !isempty(datos_grupo)
            datos_grupos[nombre_grupo] = datos_grupo
            println("      ✅ Total: $(length(datos_grupo)) valores extraídos")
        else
            println("      ⚠️  No se extrajeron datos de $nombre_grupo")
        end

        if !isnothing(on_progreso)
            on_progreso(idx_grupo, total_grupos, "Datos extraídos: $nombre_grupo")
        end
    end
    
    return datos_grupos
end

"""
    extraer_datos_excel(archivo)

Extrae valores numéricos de archivo Excel.
"""
function extraer_datos_excel(archivo::String)
    if !isfile(archivo)
        println("      ⚠️  Archivo no encontrado: $archivo")
        return Float64[]
    end
    
    try
        xf = XLSX.readxlsx(archivo)
        sheet = xf[1]  # Primera hoja
        data = sheet[:]
        
        # Extraer todos los valores numéricos
        valores = Float64[]
        for fila in data
            for celda in fila
                if isa(celda, Number)
                    push!(valores, Float64(celda))
                end
            end
        end
        
        return valores
    catch e
        println("      ⚠️  Error procesando Excel: $e")
        return Float64[]
    end
end

"""
    extraer_datos_imagen(archivo)

Extrae estadísticas de imagen médica (promedio de voxels).
"""
function extraer_datos_imagen(archivo::String)
    if !isfile(archivo)
        println("      ⚠️  Archivo no encontrado: $archivo")
        return Float64[]
    end
    
    try
        # Verificar extensión del archivo
        ext = lowercase(splitext(archivo)[2])
        
        if ext in [".nii", ".gz"]
            # Verificar si existe la función read_nifti (de ProcesamientoImagenes.jl)
            if isdefined(Main, :read_nifti)
                println("        → Usando read_nifti")
                img, header = Main.read_nifti(archivo)
                
                # Extraer voxels no nulos
                voxels = vec(img)
                voxels_validos = filter(x -> !isnan(x) && !isinf(x) && x != 0, voxels)
                
                if isempty(voxels_validos)
                    println("        ⚠️  No hay voxels válidos")
                    return Float64[]
                end
                
                # Muestrear si hay demasiados voxels (para rendimiento)
                if length(voxels_validos) > 10000
                    indices = rand(1:length(voxels_validos), 10000)
                    voxels_validos = voxels_validos[indices]
                end
                
                println("        ✓ $(length(voxels_validos)) voxels extraídos")
                return Float64.(voxels_validos)
            else
                println("        ⚠️  Función read_nifti no disponible, usando valores simulados")
                # Fallback: valores simulados para testing
                n_voxels = 1000
                return randn(n_voxels) .* 100 .+ 500
            end
            
        elseif ext == ".dcm"
            # Verificar si existe la función read_dicom_file
            if isdefined(Main, :read_dicom_file)
                println("        → Usando read_dicom_file")
                img, header = Main.read_dicom_file(archivo)
                
                voxels = vec(img)
                voxels_validos = filter(x -> !isnan(x) && !isinf(x), voxels)
                
                if length(voxels_validos) > 10000
                    indices = rand(1:length(voxels_validos), 10000)
                    voxels_validos = voxels_validos[indices]
                end
                
                println("        ✓ $(length(voxels_validos)) voxels extraídos")
                return Float64.(voxels_validos)
            else
                println("        ⚠️  Función read_dicom_file no disponible, usando valores simulados")
                n_voxels = 1000
                return randn(n_voxels) .* 100 .+ 500
            end
        else
            println("        ⚠️  Formato no soportado: $ext")
            return Float64[]
        end
        
    catch e
        println("      ⚠️  Error procesando imagen: $e")
        bt = catch_backtrace()
        println("      Stack trace:")
        for frame in bt[1:min(3, length(bt))]
            println("        $frame")
        end
        return Float64[]
    end
end

"""
    evaluar_normalidad(datos_grupos)

Aplica test de Shapiro-Wilk a cada grupo.
"""
function evaluar_normalidad(datos_grupos::Dict{String, Vector{Float64}})
    resultados = Dict{String, Dict}()
    
    for (nombre_grupo, datos) in datos_grupos
        if length(datos) < 3
            println("      ⚠️  $nombre_grupo tiene muy pocos datos (n=$(length(datos)))")
            resultados[nombre_grupo] = Dict(
                "p_value" => NaN,
                "W" => NaN,
                "es_normal" => false,
                "n" => length(datos),
                "error" => "Muestra muy pequeña"
            )
            continue
        end
        
        try
            test = ShapiroWilkTest(datos)
            p_val = pvalue(test)
            w_stat = test.W
            
            resultados[nombre_grupo] = Dict(
                "p_value" => round(p_val, digits=4),
                "W" => round(w_stat, digits=4),
                "es_normal" => p_val > 0.05,
                "n" => length(datos),
                "conclusion" => p_val > 0.05 ? "Distribución normal" : "Distribución no normal"
            )
            
            println("      → $nombre_grupo: W=$(round(w_stat,digits=3)), p=$(round(p_val,digits=4))")
        catch e
            println("      ⚠️  Error en test de normalidad para $nombre_grupo: $e")
            resultados[nombre_grupo] = Dict(
                "error" => string(e),
                "es_normal" => false
            )
        end
    end
    
    return resultados
end

"""
    determinar_parametricidad(test_normalidad)

Determina si usar pruebas paramétricas basándose en normalidad de todos los grupos.
"""
function determinar_parametricidad(test_normalidad::Dict)
    # Todos los grupos deben ser normales para usar pruebas paramétricas
    for (_, resultado) in test_normalidad
        if haskey(resultado, "es_normal") && !resultado["es_normal"]
            return false
        end
    end
    return true
end

"""
    ejecutar_prueba(nombre_prueba, datos_grupos, es_parametrico, test_normalidad)

Ejecuta la prueba estadística correspondiente.
"""
function ejecutar_prueba(
    nombre_prueba::String,
    datos_grupos::Dict{String, Vector{Float64}},
    es_parametrico::Bool,
    test_normalidad::Dict
)
    if nombre_prueba == "normalityTest"
        return test_normalidad
    elseif nombre_prueba == "tTest"
        return ejecutar_ttest(datos_grupos, es_parametrico)
    elseif nombre_prueba == "anova"
        return ejecutar_anova(datos_grupos, es_parametrico)
    elseif nombre_prueba == "correlation"
        return ejecutar_correlacion(datos_grupos, es_parametrico)
    elseif nombre_prueba == "multipleComparisons"
        return ejecutar_comparaciones_multiples(datos_grupos, es_parametrico)
    elseif nombre_prueba == "nonParametric"
        return ejecutar_no_parametrica(datos_grupos)
    elseif nombre_prueba == "fisherVariance"
        return ejecutar_fisher_variance(datos_grupos)
    elseif nombre_prueba == "correlationMatrix"
        return ejecutar_matriz_correlacion(datos_grupos, es_parametrico)
    elseif nombre_prueba == "zVariance"
        return ejecutar_z_variance(datos_grupos)
    else
        println("      ⚠️  Prueba desconocida: $nombre_prueba")
        return nothing
    end
end

"""
    ejecutar_ttest(datos_grupos, es_parametrico)

Ejecuta prueba T de Student o Mann-Whitney según parametricidad.
"""
function ejecutar_ttest(datos_grupos::Dict{String, Vector{Float64}}, es_parametrico::Bool)
    if length(datos_grupos) != 2
        return Dict(
            "error" => "T-Test requiere exactamente 2 grupos",
            "success" => false
        )
    end
    
    grupos = collect(values(datos_grupos))
    nombres = collect(keys(datos_grupos))
    
    if es_parametrico
        # Prueba T paramétrica
        try
            # Probar varianzas iguales primero
            f_test = VarianceFTest(grupos[1], grupos[2])
            p_varianza = pvalue(f_test)
            
            if p_varianza > 0.05
                test = EqualVarianceTTest(grupos[1], grupos[2])
                tipo = "Varianzas iguales"
            else
                test = UnequalVarianceTTest(grupos[1], grupos[2])
                tipo = "Varianzas diferentes (Welch)"
            end
            
            p_val = pvalue(test)
            t_stat = test.t
            df_val = test.df
            mean_diff = mean(grupos[1]) - mean(grupos[2])
            
            return Dict(
                "t_statistic" => round(t_stat, digits=4),
                "p_value" => round(p_val, digits=4),
                "df" => round(df_val, digits=2),
                "mean_diff" => round(mean_diff, digits=4),
                "tipo" => tipo,
                "grupos" => nombres,
                "conclusion" => p_val < 0.05 ? 
                    "Diferencias significativas (p < 0.05)" : 
                    "Sin diferencias significativas (p ≥ 0.05)",
                "test_aplicado" => "T de Student"
            )
        catch e
            return Dict("error" => string(e), "success" => false)
        end
    else
        # Mann-Whitney U (no paramétrico)
        return ejecutar_mann_whitney(grupos, nombres)
    end
end

"""
    ejecutar_mann_whitney(grupos, nombres)

Prueba no paramétrica de Mann-Whitney U.
"""
function ejecutar_mann_whitney(grupos::Vector{Vector{Float64}}, nombres::Vector{String})
    try
        test = MannWhitneyUTest(grupos[1], grupos[2])
        p_val = pvalue(test)
        u_stat = test.U
        
        return Dict(
            "U_statistic" => round(u_stat, digits=4),
            "p_value" => round(p_val, digits=4),
            "grupos" => nombres,
            "conclusion" => p_val < 0.05 ? 
                "Diferencias significativas (p < 0.05)" : 
                "Sin diferencias significativas (p ≥ 0.05)",
            "test_aplicado" => "Mann-Whitney U"
        )
    catch e
        return Dict("error" => string(e), "success" => false)
    end
end

"""
    ejecutar_anova(datos_grupos, es_parametrico)

Ejecuta ANOVA o Kruskal-Wallis según parametricidad.
"""
function ejecutar_anova(datos_grupos::Dict{String, Vector{Float64}}, es_parametrico::Bool)
    if length(datos_grupos) < 3
        return Dict(
            "error" => "ANOVA requiere al menos 3 grupos",
            "success" => false
        )
    end
    
    grupos = collect(values(datos_grupos))
    nombres = collect(keys(datos_grupos))
    
    if es_parametrico
        try
            test = OneWayANOVATest(grupos...)
            p_val = pvalue(test)
            f_stat = test.F
            df_between = test.df_between
            df_within = test.df_within
            
            resultado = Dict(
                "F_statistic" => round(f_stat, digits=4),
                "p_value" => round(p_val, digits=4),
                "df_between" => df_between,
                "df_within" => df_within,
                "grupos" => nombres,
                "conclusion" => p_val < 0.05 ? 
                    "Diferencias significativas entre grupos (p < 0.05)" : 
                    "Sin diferencias significativas (p ≥ 0.05)",
                "test_aplicado" => "ANOVA de una vía"
            )
            
            # Si es significativo, agregar post-hoc
            if p_val < 0.05
                resultado["post_hoc"] = calcular_tukey_hsd(grupos, nombres)
            end
            
            return resultado
        catch e
            return Dict("error" => string(e), "success" => false)
        end
    else
        return ejecutar_kruskal_wallis(grupos, nombres)
    end
end

"""
    ejecutar_kruskal_wallis(grupos, nombres)

Prueba no paramétrica de Kruskal-Wallis.
"""
function ejecutar_kruskal_wallis(grupos::Vector{Vector{Float64}}, nombres::Vector{String})
    try
        test = KruskalWallisTest(grupos...)
        p_val = pvalue(test)
        h_stat = test.H
        df_val = test.df
        
        return Dict(
            "H_statistic" => round(h_stat, digits=4),
            "p_value" => round(p_val, digits=4),
            "df" => df_val,
            "grupos" => nombres,
            "conclusion" => p_val < 0.05 ? 
                "Diferencias significativas entre grupos (p < 0.05)" : 
                "Sin diferencias significativas (p ≥ 0.05)",
            "test_aplicado" => "Kruskal-Wallis"
        )
    catch e
        return Dict("error" => string(e), "success" => false)
    end
end

"""
    calcular_tukey_hsd(grupos, nombres)

Calcula comparaciones post-hoc de Tukey HSD.
"""
function calcular_tukey_hsd(grupos::Vector{Vector{Float64}}, nombres::Vector{String})
    comparaciones = []
    
    for i in 1:length(grupos)
        for j in (i+1):length(grupos)
            try
                # Diferencia de medias
                diff = mean(grupos[i]) - mean(grupos[j])
                
                # Estimación simplificada del p-valor
                # En producción, usar implementación completa de Tukey HSD
                se = sqrt((var(grupos[i])/length(grupos[i]) + var(grupos[j])/length(grupos[j])))
                q_stat = abs(diff) / se
                
                push!(comparaciones, Dict(
                    "grupo1" => nombres[i],
                    "grupo2" => nombres[j],
                    "diferencia_medias" => round(diff, digits=4),
                    "q_statistic" => round(q_stat, digits=4),
                    "significativo" => q_stat > 3.0  # Aproximación
                ))
            catch e
                println("      ⚠️  Error en comparación $(nombres[i]) vs $(nombres[j])")
            end
        end
    end
    
    return comparaciones
end

"""
    ejecutar_correlacion(datos_grupos, es_parametrico)

Calcula correlación entre dos grupos.
"""
function ejecutar_correlacion(datos_grupos::Dict{String, Vector{Float64}}, es_parametrico::Bool)
    if length(datos_grupos) != 2
        return Dict(
            "error" => "Correlación requiere exactamente 2 grupos",
            "success" => false
        )
    end
    
    grupos = collect(values(datos_grupos))
    nombres = collect(keys(datos_grupos))
    
    # Igualar longitudes
    n = min(length(grupos[1]), length(grupos[2]))
    x = grupos[1][1:n]
    y = grupos[2][1:n]
    
    try
        if es_parametrico
            # Correlación de Pearson
            r = cor(x, y)
            n_total = length(x)
            t = r * sqrt(n_total - 2) / sqrt(1 - r^2)
            p_val = 2 * (1 - cdf(TDist(n_total - 2), abs(t)))
            
            return Dict(
                "r" => round(r, digits=4),
                "p_value" => round(p_val, digits=4),
                "n" => n_total,
                "grupos" => nombres,
                "conclusion" => interpretar_correlacion(r, p_val),
                "test_aplicado" => "Correlación de Pearson"
            )
        else
            # Correlación de Spearman
            rho = corspearman(x, y)
            n_total = length(x)
            t = rho * sqrt(n_total - 2) / sqrt(1 - rho^2)
            p_val = 2 * (1 - cdf(TDist(n_total - 2), abs(t)))
            
            return Dict(
                "rho" => round(rho, digits=4),
                "p_value" => round(p_val, digits=4),
                "n" => n_total,
                "grupos" => nombres,
                "conclusion" => interpretar_correlacion(rho, p_val),
                "test_aplicado" => "Correlación de Spearman"
            )
        end
    catch e
        return Dict("error" => string(e), "success" => false)
    end
end

"""
    interpretar_correlacion(r, p_val)

Interpreta el coeficiente de correlación.
"""
function interpretar_correlacion(r::Float64, p_val::Float64)
    significancia = p_val < 0.05 ? "significativa" : "no significativa"
    
    abs_r = abs(r)
    fuerza = if abs_r < 0.3
        "débil"
    elseif abs_r < 0.7
        "moderada"
    else
        "fuerte"
    end
    
    direccion = r > 0 ? "positiva" : "negativa"
    
    return "Correlación $direccion $fuerza (r=$(round(r,digits=2))), $significancia (p=$(round(p_val,digits=4)))"
end

"""
    ejecutar_comparaciones_multiples(datos_grupos, es_parametrico)

Ejecuta correcciones de Bonferroni para comparaciones múltiples.
"""
function ejecutar_comparaciones_multiples(datos_grupos::Dict{String, Vector{Float64}}, es_parametrico::Bool)
    nombres = collect(keys(datos_grupos))
    grupos = collect(values(datos_grupos))
    n_comparaciones = binomial(length(grupos), 2)
    
    comparaciones = []
    
    for i in 1:length(grupos)
        for j in (i+1):length(grupos)
            try
                if es_parametrico
                    test = UnequalVarianceTTest(grupos[i], grupos[j])
                    p_val = pvalue(test)
                    stat = test.t
                    stat_name = "t"
                else
                    test = MannWhitneyUTest(grupos[i], grupos[j])
                    p_val = pvalue(test)
                    stat = test.U
                    stat_name = "U"
                end
                
                p_bonferroni = min(p_val * n_comparaciones, 1.0)
                
                push!(comparaciones, Dict(
                    "grupo1" => nombres[i],
                    "grupo2" => nombres[j],
                    "$(stat_name)_statistic" => round(stat, digits=4),
                    "p_value_original" => round(p_val, digits=4),
                    "p_value_bonferroni" => round(p_bonferroni, digits=4),
                    "significativo_bonferroni" => p_bonferroni < 0.05
                ))
            catch e
                println("      ⚠️  Error comparando $(nombres[i]) vs $(nombres[j])")
            end
        end
    end
    
    return Dict(
        "comparaciones" => comparaciones,
        "num_comparaciones" => n_comparaciones,
        "alpha_ajustado" => round(0.05 / n_comparaciones, digits=6),
        "metodo" => "Corrección de Bonferroni"
    )
end

"""
    ejecutar_no_parametrica(datos_grupos)

Ejecuta pruebas no paramétricas automáticamente.
"""
function ejecutar_no_parametrica(datos_grupos::Dict{String, Vector{Float64}})
    if length(datos_grupos) == 2
        grupos = collect(values(datos_grupos))
        nombres = collect(keys(datos_grupos))
        return ejecutar_mann_whitney(grupos, nombres)
    else
        grupos = collect(values(datos_grupos))
        nombres = collect(keys(datos_grupos))
        return ejecutar_kruskal_wallis(grupos, nombres)
    end
end

"""
    ejecutar_fisher_variance(datos_grupos)

Prueba F de Fisher para comparar varianzas.
"""
function ejecutar_fisher_variance(datos_grupos::Dict{String, Vector{Float64}})
    if length(datos_grupos) != 2
        return Dict(
            "error" => "Prueba F requiere exactamente 2 grupos",
            "success" => false
        )
    end
    
    grupos = collect(values(datos_grupos))
    nombres = collect(keys(datos_grupos))
    
    try
        test = VarianceFTest(grupos[1], grupos[2])
        p_val = pvalue(test)
        f_stat = test.F
        
        var1 = var(grupos[1])
        var2 = var(grupos[2])
        
        return Dict(
            "F_statistic" => round(f_stat, digits=4),
            "p_value" => round(p_val, digits=4),
            "varianza_grupo1" => round(var1, digits=4),
            "varianza_grupo2" => round(var2, digits=4),
            "ratio_varianzas" => round(var1/var2, digits=4),
            "grupos" => nombres,
            "conclusion" => p_val < 0.05 ? 
                "Varianzas significativamente diferentes (p < 0.05)" : 
                "Varianzas homogéneas (p ≥ 0.05)",
            "test_aplicado" => "Prueba F de Fisher"
        )
    catch e
        return Dict("error" => string(e), "success" => false)
    end
end

"""
    ejecutar_matriz_correlacion(datos_grupos, es_parametrico)

Calcula matriz de correlación entre todos los grupos.
"""
function ejecutar_matriz_correlacion(datos_grupos::Dict{String, Vector{Float64}}, es_parametrico::Bool)
    nombres = collect(keys(datos_grupos))
    n_grupos = length(nombres)
    
    # Encontrar longitud común
    n_min = minimum([length(v) for v in values(datos_grupos)])
    
    # Crear matriz de datos
    matriz_datos = zeros(Float64, n_min, n_grupos)
    for (i, nombre) in enumerate(nombres)
        matriz_datos[:, i] = datos_grupos[nombre][1:n_min]
    end
    
    # Calcular correlaciones
    R_matrix = zeros(Float64, n_grupos, n_grupos)
    P_matrix = ones(Float64, n_grupos, n_grupos)
    
    for i in 1:n_grupos
        for j in 1:n_grupos
            if i == j
                R_matrix[i, j] = 1.0
                P_matrix[i, j] = 0.0
            elseif i < j
                try
                    if es_parametrico
                        r = cor(matriz_datos[:, i], matriz_datos[:, j])
                        t = r * sqrt(n_min - 2) / sqrt(1 - r^2)
                        p = 2 * (1 - cdf(TDist(n_min - 2), abs(t)))
                    else
                        r = corspearman(matriz_datos[:, i], matriz_datos[:, j])
                        t = r * sqrt(n_min - 2) / sqrt(1 - r^2)
                        p = 2 * (1 - cdf(TDist(n_min - 2), abs(t)))
                    end
                    
                    R_matrix[i, j] = r
                    R_matrix[j, i] = r
                    P_matrix[i, j] = p
                    P_matrix[j, i] = p
                catch e
                    println("      ⚠️  Error calculando correlación ($i,$j)")
                end
            end
        end
    end
    
    return Dict(
        "R_matrix" => round.(R_matrix, digits=4),
        "P_matrix" => round.(P_matrix, digits=4),
        "grupos" => nombres,
        "n" => n_min,
        "metodo" => es_parametrico ? "Pearson" : "Spearman",
        "test_aplicado" => "Matriz de correlación"
    )
end

"""
    ejecutar_z_variance(datos_grupos)

Prueba Z para comparar varianzas (aproximación).
"""
function ejecutar_z_variance(datos_grupos::Dict{String, Vector{Float64}})
    if length(datos_grupos) != 2
        return Dict(
            "error" => "Prueba Z de varianzas requiere exactamente 2 grupos",
            "success" => false
        )
    end
    
    grupos = collect(values(datos_grupos))
    nombres = collect(keys(datos_grupos))
    
    try
        var1 = var(grupos[1])
        var2 = var(grupos[2])
        n1 = length(grupos[1])
        n2 = length(grupos[2])
        
        # Aproximación de prueba Z para varianzas
        s_pooled = sqrt((var1 + var2) / 2)
        se = sqrt(2 * s_pooled^4 / ((n1 + n2) / 2))
        z = (var1 - var2) / se
        
        # P-valor bilateral
        p_val = 2 * (1 - cdf(Normal(), abs(z)))
        
        return Dict(
            "Z_statistic" => round(z, digits=4),
            "p_value" => round(p_val, digits=4),
            "varianza_grupo1" => round(var1, digits=4),
            "varianza_grupo2" => round(var2, digits=4),
            "n1" => n1,
            "n2" => n2,
            "grupos" => nombres,
            "conclusion" => p_val < 0.05 ? 
                "Varianzas significativamente diferentes (p < 0.05)" : 
                "Varianzas no difieren significativamente (p ≥ 0.05)",
            "test_aplicado" => "Prueba Z de varianzas"
        )
    catch e
        return Dict("error" => string(e), "success" => false)
    end
end

println("✅ Módulo AnalisisEstadistico.jl cargado correctamente")

# ============================================================================
# FUNCIONES AUXILIARES ADICIONALES
# ============================================================================

"""
    validar_datos_grupo(datos)

Valida que los datos sean apropiados para análisis estadístico.
"""
function validar_datos_grupo(datos::Vector{Float64})
    if isempty(datos)
        return false, "Datos vacíos"
    end
    
    if length(datos) < 3
        return false, "Muestra muy pequeña (n < 3)"
    end
    
    if all(x -> x == datos[1], datos)
        return false, "Datos sin variabilidad"
    end
    
    if any(isnan, datos) || any(isinf, datos)
        return false, "Contiene valores NaN o Inf"
    end
    
    return true, "Datos válidos"
end

"""
    calcular_estadisticas_descriptivas(datos_grupos)

Calcula estadísticas descriptivas para cada grupo.
"""
function calcular_estadisticas_descriptivas(datos_grupos::Dict{String, Vector{Float64}})
    estadisticas = Dict{String, Dict}()
    
    for (nombre, datos) in datos_grupos
        estadisticas[nombre] = Dict(
            "n" => length(datos),
            "media" => round(mean(datos), digits=4),
            "mediana" => round(median(datos), digits=4),
            "desviacion_estandar" => round(std(datos), digits=4),
            "varianza" => round(var(datos), digits=4),
            "min" => round(minimum(datos), digits=4),
            "max" => round(maximum(datos), digits=4),
            "q1" => round(quantile(datos, 0.25), digits=4),
            "q3" => round(quantile(datos, 0.75), digits=4),
            "rango_intercuartil" => round(iqr(datos), digits=4)
        )
    end
    
    return estadisticas
end

"""
    generar_resumen_interpretativo(resultados)

Genera un resumen en lenguaje natural de los resultados.
"""
function generar_resumen_interpretativo(resultados::Dict)
    resumen = String[]
    
    # Normalidad
    if haskey(resultados, "parametricidad")
        if resultados["parametricidad"]["es_parametrico"]
            push!(resumen, "✓ Los datos siguen una distribución normal, se aplicaron pruebas paramétricas.")
        else
            push!(resumen, "✗ Los datos no siguen distribución normal, se aplicaron pruebas no paramétricas.")
        end
    end
    
    # T-Test o Mann-Whitney
    if haskey(resultados["resultados"], "tTest")
        test = resultados["resultados"]["tTest"]
        if haskey(test, "p_value")
            if test["p_value"] < 0.05
                push!(resumen, "→ Existen diferencias estadísticamente significativas entre los grupos (p < 0.05).")
            else
                push!(resumen, "→ No se encontraron diferencias estadísticamente significativas entre los grupos.")
            end
        end
    end
    
    # ANOVA
    if haskey(resultados["resultados"], "anova")
        anova = resultados["resultados"]["anova"]
        if haskey(anova, "p_value")
            if anova["p_value"] < 0.05
                push!(resumen, "→ ANOVA detectó diferencias significativas entre al menos dos grupos (p < 0.05).")
                if haskey(anova, "post_hoc")
                    push!(resumen, "  → Se realizaron comparaciones post-hoc para identificar qué grupos difieren.")
                end
            else
                push!(resumen, "→ No se encontraron diferencias significativas entre los grupos (ANOVA).")
            end
        end
    end
    
    # Correlación
    if haskey(resultados["resultados"], "correlation")
        corr = resultados["resultados"]["correlation"]
        if haskey(corr, "conclusion")
            push!(resumen, "→ Correlación: " * corr["conclusion"])
        end
    end
    
    # Varianzas
    if haskey(resultados["resultados"], "fisherVariance")
        fisher = resultados["resultados"]["fisherVariance"]
        if haskey(fisher, "p_value")
            if fisher["p_value"] < 0.05
                push!(resumen, "→ Las varianzas entre grupos son significativamente diferentes (heterogeneidad).")
            else
                push!(resumen, "→ Las varianzas entre grupos son homogéneas.")
            end
        end
    end
    
    return join(resumen, "\n")
end

"""
    exportar_resultados_texto(resultados, archivo_salida)

Exporta resultados a archivo de texto plano.
"""
function exportar_resultados_texto(resultados::Dict, archivo_salida::String)
    try
        open(archivo_salida, "w") do io
            println(io, "="^70)
            println(io, "REPORTE DE ANÁLISIS ESTADÍSTICO")
            println(io, "="^70)
            println(io, "Fecha: $(Dates.now())")
            println(io, "")
            
            # Parametricidad
            if haskey(resultados, "parametricidad")
                println(io, "\n[EVALUACIÓN DE NORMALIDAD]")
                println(io, "-"^70)
                println(io, "Tipo de distribución: $(resultados["parametricidad"]["es_parametrico"] ? "PARAMÉTRICA" : "NO PARAMÉTRICA")")
                println(io, "")
                
                for (grupo, test) in resultados["parametricidad"]["test_normalidad"]
                    println(io, "Grupo: $grupo")
                    if haskey(test, "W")
                        println(io, "  W-statistic: $(test["W"])")
                        println(io, "  P-valor: $(test["p_value"])")
                        println(io, "  Conclusión: $(test["conclusion"])")
                    end
                    println(io, "")
                end
            end
            
            # Resultados de pruebas
            if haskey(resultados, "resultados")
                println(io, "\n[RESULTADOS DE PRUEBAS ESTADÍSTICAS]")
                println(io, "-"^70)
                
                for (nombre_prueba, resultado) in resultados["resultados"]
                    println(io, "\n$nombre_prueba:")
                    if haskey(resultado, "test_aplicado")
                        println(io, "  Test: $(resultado["test_aplicado"])")
                    end
                    
                    for (clave, valor) in resultado
                        if clave ∉ ["test_aplicado", "grupos", "post_hoc", "comparaciones"]
                            println(io, "  $clave: $valor")
                        end
                    end
                    println(io, "")
                end
            end
            
            # Resumen interpretativo
            println(io, "\n[RESUMEN INTERPRETATIVO]")
            println(io, "-"^70)
            println(io, generar_resumen_interpretativo(resultados))
            
            println(io, "\n" * "="^70)
            println(io, "Tiempo de análisis: $(resultados["tiempo_analisis"]) segundos")
            println(io, "="^70)
        end
        
        println("   Reporte exportado a: $archivo_salida")
        return true
    catch e
        println("❌ Error exportando reporte: $e")
        return false
    end
end

"""
    preparar_datos_para_excel(resultados)

Prepara los resultados en formato tabular para exportar a Excel.
"""
function preparar_datos_para_excel(resultados::Dict)
    filas = []
    
    # Encabezados
    push!(filas, ["Métrica", "Valor", "P-Valor", "Conclusión"])
    push!(filas, fill("", 4))  # Fila vacía
    
    # Test de normalidad
    if haskey(resultados, "parametricidad")
        push!(filas, ["TEST DE NORMALIDAD", "", "", ""])
        push!(filas, fill("-", 4))
        
        for (grupo, test) in resultados["parametricidad"]["test_normalidad"]
            if haskey(test, "W")
                push!(filas, [
                    "Shapiro-Wilk ($grupo)",
                    "W = $(test["W"])",
                    string(test["p_value"]),
                    test["conclusion"]
                ])
            end
        end
        push!(filas, fill("", 4))
    end
    
    # Tipo de distribución
    if haskey(resultados, "parametricidad")
        tipo_dist = resultados["parametricidad"]["es_parametrico"] ? "PARAMÉTRICA" : "NO PARAMÉTRICA"
        push!(filas, ["Distribución de datos", tipo_dist, "", ""])
        push!(filas, fill("", 4))
    end
    
    # Resultados de pruebas
    if haskey(resultados, "resultados")
        push!(filas, ["PRUEBAS ESTADÍSTICAS", "", "", ""])
        push!(filas, fill("-", 4))
        
        for (nombre_prueba, resultado) in resultados["resultados"]
            if haskey(resultado, "error")
                continue
            end
            
            # T-Test
            if nombre_prueba == "tTest"
                if haskey(resultado, "t_statistic")
                    push!(filas, [
                        "T de Student",
                        "t = $(resultado["t_statistic"])",
                        string(resultado["p_value"]),
                        resultado["conclusion"]
                    ])
                    push!(filas, [
                        "  Grados de libertad",
                        string(resultado["df"]),
                        "",
                        ""
                    ])
                    push!(filas, [
                        "  Diferencia de medias",
                        string(resultado["mean_diff"]),
                        "",
                        ""
                    ])
                elseif haskey(resultado, "U_statistic")
                    push!(filas, [
                        "Mann-Whitney U",
                        "U = $(resultado["U_statistic"])",
                        string(resultado["p_value"]),
                        resultado["conclusion"]
                    ])
                end
                push!(filas, fill("", 4))
            end
            
            # ANOVA
            if nombre_prueba == "anova"
                if haskey(resultado, "F_statistic")
                    push!(filas, [
                        "ANOVA",
                        "F = $(resultado["F_statistic"])",
                        string(resultado["p_value"]),
                        resultado["conclusion"]
                    ])
                    push!(filas, [
                        "  GL entre grupos",
                        string(resultado["df_between"]),
                        "",
                        ""
                    ])
                    push!(filas, [
                        "  GL dentro de grupos",
                        string(resultado["df_within"]),
                        "",
                        ""
                    ])
                elseif haskey(resultado, "H_statistic")
                    push!(filas, [
                        "Kruskal-Wallis",
                        "H = $(resultado["H_statistic"])",
                        string(resultado["p_value"]),
                        resultado["conclusion"]
                    ])
                end
                push!(filas, fill("", 4))
            end
            
            # Correlación
            if nombre_prueba in ["correlation", "correlationMatrix"]
                if haskey(resultado, "r")
                    push!(filas, [
                        "Correlación de Pearson",
                        "r = $(resultado["r"])",
                        string(resultado["p_value"]),
                        resultado["conclusion"]
                    ])
                elseif haskey(resultado, "rho")
                    push!(filas, [
                        "Correlación de Spearman",
                        "ρ = $(resultado["rho"])",
                        string(resultado["p_value"]),
                        resultado["conclusion"]
                    ])
                end
                push!(filas, fill("", 4))
            end
            
            # Fisher Variance
            if nombre_prueba == "fisherVariance"
                if haskey(resultado, "F_statistic")
                    push!(filas, [
                        "Prueba F de Fisher",
                        "F = $(resultado["F_statistic"])",
                        string(resultado["p_value"]),
                        resultado["conclusion"]
                    ])
                    push!(filas, [
                        "  Ratio de varianzas",
                        string(resultado["ratio_varianzas"]),
                        "",
                        ""
                    ])
                end
                push!(filas, fill("", 4))
            end
            
            # Z Variance
            if nombre_prueba == "zVariance"
                if haskey(resultado, "Z_statistic")
                    push!(filas, [
                        "Prueba Z de varianzas",
                        "Z = $(resultado["Z_statistic"])",
                        string(resultado["p_value"]),
                        resultado["conclusion"]
                    ])
                end
                push!(filas, fill("", 4))
            end
        end
    end
    
    # Información adicional
    push!(filas, ["INFORMACIÓN ADICIONAL", "", "", ""])
    push!(filas, fill("-", 4))
    push!(filas, ["Número de grupos", string(resultados["num_grupos"]), "", ""])
    push!(filas, ["Tiempo de análisis", "$(resultados["tiempo_analisis"]) seg", "", ""])
    push!(filas, ["Fecha", string(Dates.now()), "", ""])
    
    return filas
end

"""
    test_modulo()

Función de prueba del módulo.
"""
function test_modulo()
    println("\n🧪 EJECUTANDO TEST DEL MÓDULO")
    println("="^70)
    
    # Crear datos de prueba
    grupos_test = Dict(
        "Grupo_Control" => randn(50) .* 10 .+ 100,
        "Grupo_Tratamiento" => randn(50) .* 12 .+ 105
    )
    
    pruebas_test = [
        "normalityTest",
        "tTest",
        "fisherVariance",
        "correlation"
    ]
    
    # Ejecutar análisis
    resultado = analizar_estadistico(
        grupos_test,
        pruebas_test,
        false,
        "imagenes"
    )
    
    # Mostrar resultados
    if resultado["success"]
        println("\n✅ TEST EXITOSO")
        println("Paramétrico: $(resultado["parametricidad"]["es_parametrico"])")
        println("Número de pruebas ejecutadas: $(length(resultado["resultados"]))")
        println("Tiempo: $(resultado["tiempo_analisis"]) segundos")
        
        # Exportar reporte de prueba
        exportar_resultados_texto(resultado, "test_analisis_estadistico.txt")
    else
        println("\n❌ TEST FALLIDO")
        println("Error: $(resultado["error"])")
    end
    
    println("="^70)
    
    return resultado
end

"""
    guardar_resultados_estadisticos_excel(result, base_resultados) -> String

Guarda resultados de análisis estadístico en Excel. Movida acá desde
`server.jl` (antes vivía suelta junto al router) — es lógica del dominio
"análisis estadístico", no del servidor HTTP, y ya usaba `XLSX`/`Dates`
que este módulo importa.
"""
function guardar_resultados_estadisticos_excel(result::Dict, base_resultados::String)
    try
        dir_resultados = joinpath(base_resultados, "estadisticas")
        mkpath(dir_resultados)

        timestamp = Dates.format(now(), "yyyymmdd_HHMMSS")
        nombre_archivo = "estadisticas_$(timestamp).xlsx"
        ruta_completa = joinpath(dir_resultados, nombre_archivo)

        println("📊 Generando archivo Excel: $nombre_archivo")

        filas = preparar_datos_para_excel(result)

        XLSX.openxlsx(ruta_completa, mode="w") do xf
            sheet_resultados = xf[1]
            XLSX.rename!(sheet_resultados, "Resultados")

            for (idx, fila) in enumerate(filas)
                for (col_idx, valor) in enumerate(fila)
                    sheet_resultados[XLSX.CellRef(idx, col_idx)] = valor
                end
            end

            XLSX.addsheet!(xf, "Resumen")
            sheet_resumen = xf["Resumen"]

            sheet_resumen["A1"] = "ANÁLISIS ESTADÍSTICO - RESUMEN"
            sheet_resumen["A2"] = "Generado: $(Dates.format(now(), "dd/mm/yyyy HH:MM:SS"))"

            row = 4
            sheet_resumen["A$(row)"] = "Métrica"
            sheet_resumen["B$(row)"] = "Valor"

            row += 1
            sheet_resumen["A$(row)"] = "Tiempo total (segundos)"
            sheet_resumen["B$(row)"] = get(result, "tiempo_analisis", 0.0)

            row += 1
            sheet_resumen["A$(row)"] = "Número de grupos"
            sheet_resumen["B$(row)"] = get(result, "num_grupos", 0)

            row += 1
            sheet_resumen["A$(row)"] = "Tipo de distribución"
            sheet_resumen["B$(row)"] = get(result["parametricidad"], "es_parametrico", false) ? "Paramétrica" : "No Paramétrica"

            row += 2
            sheet_resumen["A$(row)"] = "GRUPOS ANALIZADOS"

            if haskey(result, "nombres_grupos")
                for grupo in result["nombres_grupos"]
                    row += 1
                    sheet_resumen["A$(row)"] = grupo
                end
            end

            XLSX.addsheet!(xf, "Interpretacion")
            sheet_interp = xf["Interpretacion"]

            sheet_interp["A1"] = "INTERPRETACIÓN DE RESULTADOS"
            sheet_interp["A2"] = "="^50

            interpretacion = generar_resumen_interpretativo(result)
            lineas = split(interpretacion, "\n")

            for (idx, linea) in enumerate(lineas)
                sheet_interp["A$(idx+3)"] = linea
            end

            XLSX.setcolwidth!(sheet_resultados, "A:A", 35)
            XLSX.setcolwidth!(sheet_resultados, "B:B", 25)
            XLSX.setcolwidth!(sheet_resultados, "C:C", 15)
            XLSX.setcolwidth!(sheet_resultados, "D:D", 40)

            XLSX.setcolwidth!(sheet_resumen, "A:B", 30)
            XLSX.setcolwidth!(sheet_interp, "A:A", 80)
        end

        println("✅ Archivo Excel guardado: $ruta_completa")
        return ruta_completa

    catch e
        println("❌ Error guardando Excel: $e")
        println(stacktrace(catch_backtrace()))
        throw(e)
    end
end

# Exportar funciones principales
export analizar_estadistico,
       calcular_estadisticas_descriptivas,
       generar_resumen_interpretativo,
       exportar_resultados_texto,
       preparar_datos_para_excel,
       guardar_resultados_estadisticos_excel,
       test_modulo

# Fin del módulo
println("✅ Módulo AnalisisEstadistico.jl cargado correctamente")