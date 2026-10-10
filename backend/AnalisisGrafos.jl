# ==============================================================================
# AnalisisGrafos.jl — Módulo de dominio: análisis por grafos (4º módulo)
# ==============================================================================
#
# FASE 1 de la implementación: realce vascular + binarización — "¿el filtro
# encuentra algo parecido a vasos?" (validable visualmente con las 2
# imágenes que devuelve cada resultado). La esqueletización y la
# extracción del grafo (nodos/aristas/métricas) son la Fase 2, todavía no
# implementada — por eso el resultado de cada archivo trae
# `"fase_pipeline"` en vez de pretender tener un grafo ya armado.
#
# Ver docs/CAMBIOS_PARA_GRAFOS.md para la explicación física de cada paso
# y cómo interpretar cada medida, y para el detalle de todas las
# decisiones de diseño (por qué Frangi, por qué Otsu, limitaciones
# conocidas, etc.).
#
# Dispatch por `tipo_grafo` (mismo patrón que `tipo_datos` en
# AnalisisEstadistico.jl): "vascular" (esta fase) vs "conectividad"
# (reservado, el handler lo rechaza con 501 antes de llegar acá).
#
# Implementación propia en Julia (sin PyCall/Python) para este paso en
# particular — coherente con AnalisisRadiomico.jl. Reutiliza los lectores
# de volumen ya existentes en AnalisisRadiomico.jl
# (`detectar_tipo_archivo`, `leer_volumen_nifti`, `leer_volumen_dicom`) y
# el encoder de imágenes de ProcesamientoImagenes.jl (`extract_slice`,
# `matrix_to_base64_png`) — ambos ya están en `Main` cuando este archivo
# se carga (ver orden de `include` en server.jl).
# ==============================================================================

using Dates
using XLSX

# ==============================================================================
# SUAVIZADO GAUSSIANO 3D (separable, con σ en mm convertido a vóxeles por
# eje — así un voxel anisotrópico, ej. 1×1×3mm, no distorsiona la escala
# efectiva del filtro en el eje de corte grueso).
# ==============================================================================

"""
Kernel Gaussiano 1D discreto y normalizado. Radio = ceil(3σ) vóxeles
(captura ~99.7% del área de la Gaussiana).
"""
function _kernel_gaussiano_1d(sigma::Float64)
    sigma = max(sigma, 1e-6)
    radio = max(1, ceil(Int, 3 * sigma))
    xs = collect(-radio:radio)
    k = exp.(-(xs .^ 2) ./ (2 * sigma^2))
    k ./= sum(k)
    return k
end

# Tres funciones casi idénticas (una por eje) en vez de una genérica
# parametrizada por dimensión: evita indexado dinámico (CartesianIndex)
# en el loop más caliente del módulo — con volúmenes de varios millones
# de vóxeles × 3 escalas, esa indirección sí se nota.
function _convolve_x(vol::Array{Float64,3}, kernel::Vector{Float64})
    radio = (length(kernel) - 1) ÷ 2
    nx, ny, nz = size(vol)
    out = similar(vol)
    @inbounds Threads.@threads for k in 1:nz
        for j in 1:ny, i in 1:nx
            acc = 0.0
            for t in 1:length(kernel)
                ii = clamp(i + (t - radio - 1), 1, nx)
                acc += kernel[t] * vol[ii, j, k]
            end
            out[i, j, k] = acc
        end
    end
    return out
end

function _convolve_y(vol::Array{Float64,3}, kernel::Vector{Float64})
    radio = (length(kernel) - 1) ÷ 2
    nx, ny, nz = size(vol)
    out = similar(vol)
    @inbounds Threads.@threads for k in 1:nz
        for j in 1:ny, i in 1:nx
            acc = 0.0
            for t in 1:length(kernel)
                jj = clamp(j + (t - radio - 1), 1, ny)
                acc += kernel[t] * vol[i, jj, k]
            end
            out[i, j, k] = acc
        end
    end
    return out
end

function _convolve_z(vol::Array{Float64,3}, kernel::Vector{Float64})
    radio = (length(kernel) - 1) ÷ 2
    nx, ny, nz = size(vol)
    out = similar(vol)
    @inbounds Threads.@threads for k in 1:nz
        for j in 1:ny, i in 1:nx
            acc = 0.0
            for t in 1:length(kernel)
                kk = clamp(k + (t - radio - 1), 1, nz)
                acc += kernel[t] * vol[i, j, kk]
            end
            out[i, j, k] = acc
        end
    end
    return out
end

"""
    suavizar_gaussiano_3d(vol, sigma_x, sigma_y, sigma_z)

Suavizado Gaussiano 3D separable (3 pasadas 1D), con σ posiblemente
distinto por eje — ya convertido a vóxeles por el llamador
(`sigma_mm / voxel_dims[eje]`).
"""
function suavizar_gaussiano_3d(vol::Array{Float64,3}, sigma_x::Float64, sigma_y::Float64, sigma_z::Float64)
    vx = _convolve_x(vol, _kernel_gaussiano_1d(sigma_x))
    vxy = _convolve_y(vx, _kernel_gaussiano_1d(sigma_y))
    return _convolve_z(vxy, _kernel_gaussiano_1d(sigma_z))
end

# ==============================================================================
# HESSIANA 3D (diferencias finitas centradas sobre el volumen ya
# suavizado — "suavizar y luego derivar" es equivalente, en la práctica, a
# convolucionar con derivadas-de-Gaussiana, pero mucho más simple de
# escribir e inspeccionar).
# ==============================================================================

"""
Las 6 componentes únicas de la matriz Hessiana 3×3 (simétrica) en cada
vóxel, vía diferencias finitas centradas de 2º orden. Bordes replicados
(`clamp`) en vez de asumir ceros fuera del volumen.
"""
function _hessiana_3d(vol::Array{Float64,3})
    nx, ny, nz = size(vol)
    Ixx = similar(vol); Iyy = similar(vol); Izz = similar(vol)
    Ixy = similar(vol); Ixz = similar(vol); Iyz = similar(vol)

    @inbounds Threads.@threads for k in 1:nz
        kp = clamp(k + 1, 1, nz); km = clamp(k - 1, 1, nz)
        for j in 1:ny
            jp = clamp(j + 1, 1, ny); jm = clamp(j - 1, 1, ny)
            for i in 1:nx
                ip = clamp(i + 1, 1, nx); im = clamp(i - 1, 1, nx)
                c = vol[i, j, k]

                Ixx[i, j, k] = vol[ip, j, k] - 2c + vol[im, j, k]
                Iyy[i, j, k] = vol[i, jp, k] - 2c + vol[i, jm, k]
                Izz[i, j, k] = vol[i, j, kp] - 2c + vol[i, j, km]

                Ixy[i, j, k] = (vol[ip, jp, k] - vol[ip, jm, k] - vol[im, jp, k] + vol[im, jm, k]) / 4.0
                Ixz[i, j, k] = (vol[ip, j, kp] - vol[ip, j, km] - vol[im, j, kp] + vol[im, j, km]) / 4.0
                Iyz[i, j, k] = (vol[i, jp, kp] - vol[i, jp, km] - vol[i, jm, kp] + vol[i, jm, km]) / 4.0
            end
        end
    end
    return Ixx, Iyy, Izz, Ixy, Ixz, Iyz
end

# ==============================================================================
# EIGENVALORES DE UNA SIMÉTRICA 3×3 EN FORMA CERRADA
# ==============================================================================
#
# Con millones de vóxeles × varias escalas, llamar a `LinearAlgebra.eigen`
# (que despacha a LAPACK) por cada vóxel sería, por lejos, el cuello de
# botella del filtro completo — LAPACK está pensado para matrices
# grandes, no para resolver matrices de 3×3 decenas de millones de veces.
# Acá se usa el método trigonométrico de Smith (1961): fórmula cerrada
# basada en los invariantes de la matriz (traza, determinante de la parte
# desviadora), sin ningún llamado a una librería externa.

@inline function _eigenvalores_sim_3x3(a11, a22, a33, a12, a13, a23)
    p1 = a12^2 + a13^2 + a23^2
    if p1 < 1e-30
        # Ya es (esencialmente) diagonal.
        return a11, a22, a33
    end

    q = (a11 + a22 + a33) / 3.0
    p2 = (a11 - q)^2 + (a22 - q)^2 + (a33 - q)^2 + 2 * p1
    p = sqrt(p2 / 6.0)

    b11 = (a11 - q) / p; b22 = (a22 - q) / p; b33 = (a33 - q) / p
    b12 = a12 / p; b13 = a13 / p; b23 = a23 / p

    detB = b11 * b22 * b33 + 2 * b12 * b13 * b23 - b11 * b23^2 - b22 * b13^2 - b33 * b12^2
    r = clamp(detB / 2.0, -1.0, 1.0)
    phi = acos(r) / 3.0

    eig3 = q + 2 * p * cos(phi)
    eig1 = q + 2 * p * cos(phi + 2 * pi / 3)
    eig2 = 3 * q - eig1 - eig3   # traza = eig1+eig2+eig3 = 3q

    return eig1, eig2, eig3
end

"""Reordena 3 eigenvalores por VALOR ABSOLUTO ascendente (|λ1|≤|λ2|≤|λ3|)
— el orden que usa el criterio de Frangi, no el orden algebraico."""
@inline function _ordenar_por_abs(l1, l2, l3)
    if abs(l1) > abs(l2); l1, l2 = l2, l1; end
    if abs(l2) > abs(l3); l2, l3 = l3, l2; end
    if abs(l1) > abs(l2); l1, l2 = l2, l1; end
    return l1, l2, l3
end

# ==============================================================================
# FILTRO DE VESSELNESS (Frangi, 1998) — multi-escala
# ==============================================================================

"""
Vesselness de Frangi para UNA escala σ (en mm). Devuelve un volumen
`Float64` del mismo tamaño que `vol`, con un score en [0,1] por vóxel
("qué tan parecido a un tubo brillante es este vóxel, a este calibre").
"""
function _frangi_una_escala(vol::Array{Float64,3}, voxel_dims, sigma_mm::Float64,
                             alpha::Float64, beta::Float64, c_override::Union{Float64,Nothing})
    sx, sy, sz = voxel_dims
    suavizado = suavizar_gaussiano_3d(vol, sigma_mm / sx, sigma_mm / sy, sigma_mm / sz)
    Ixx, Iyy, Izz, Ixy, Ixz, Iyz = _hessiana_3d(suavizado)

    # Normalización de escala (Lindeberg, γ=2): sin esto, un σ más grande
    # da respuestas sistemáticamente más chicas aunque el vaso de ese
    # calibre sí esté presente — esto iguala la comparación entre escalas.
    factor = sigma_mm^2
    nx, ny, nz = size(vol)

    l1 = similar(vol); l2 = similar(vol); l3 = similar(vol)
    @inbounds Threads.@threads for k in 1:nz
        for j in 1:ny, i in 1:nx
            e1, e2, e3 = _eigenvalores_sim_3x3(
                Ixx[i, j, k] * factor, Iyy[i, j, k] * factor, Izz[i, j, k] * factor,
                Ixy[i, j, k] * factor, Ixz[i, j, k] * factor, Iyz[i, j, k] * factor,
            )
            l1[i, j, k], l2[i, j, k], l3[i, j, k] = _ordenar_por_abs(e1, e2, e3)
        end
    end

    # `c` (Frangi): mitad de la "estructura máxima" (norma de Frobenius de
    # la Hessiana) observada en el volumen a esta escala — adaptativo a la
    # escala de intensidades de cada imagen (MRI no viene en unidades
    # estandarizadas). Si se da `c_override`, se usa ese valor fijo.
    c = c_override
    if isnothing(c)
        max_S = 0.0
        @inbounds for idx in eachindex(l1)
            s = sqrt(l1[idx]^2 + l2[idx]^2 + l3[idx]^2)
            max_S = max(max_S, s)
        end
        c = max_S > 0 ? max_S / 2 : 1.0
    end

    eps_ = 1e-12
    vesselness = similar(vol)
    @inbounds Threads.@threads for idx in eachindex(vesselness)
        la1, la2, la3 = l1[idx], l2[idx], l3[idx]
        if la2 >= 0 || la3 >= 0
            # Filtro para estructuras BRILLANTES sobre fondo oscuro
            # (vasos realzados por contraste): un tubo brillante tiene las
            # 2 curvaturas transversales grandes y NEGATIVAS. Si no se
            # cumple, este vóxel no es candidato a vaso en esta escala.
            vesselness[idx] = 0.0
        else
            la3_abs = max(abs(la3), eps_)
            Ra = abs(la2) / la3_abs                                   # línea vs. placa
            Rb = abs(la1) / sqrt(max(abs(la2 * la3), eps_))           # línea vs. blob
            S = sqrt(la1^2 + la2^2 + la3^2)                           # fuerza de estructura
            vesselness[idx] = (1 - exp(-(Ra^2) / (2 * alpha^2))) *
                               exp(-(Rb^2) / (2 * beta^2)) *
                               (1 - exp(-(S^2) / (2 * c^2)))
        end
    end
    return vesselness
end

"""
    calcular_vesselness(volumen, voxel_dims; escalas_mm, alpha, beta, c_override)

Vesselness multi-escala: corre `_frangi_una_escala` para cada σ en
`escalas_mm` y se queda, vóxel a vóxel, con el máximo entre escalas (un
vóxel puede pertenecer a un vaso grueso O a uno delgado — cualquiera de
las dos lecturas lo marca como "vascular").
"""
function calcular_vesselness(volumen::Array{Float64,3}, voxel_dims;
                              escalas_mm::Vector{Float64}=[1.0, 2.0, 3.0],
                              alpha::Float64=0.5, beta::Float64=0.5,
                              c_override::Union{Float64,Nothing}=nothing)
    mejor = zeros(Float64, size(volumen))
    for sigma_mm in escalas_mm
        v = _frangi_una_escala(volumen, voxel_dims, sigma_mm, alpha, beta, c_override)
        mejor .= max.(mejor, v)
    end
    return mejor
end

# ==============================================================================
# UMBRAL DE OTSU — separa automáticamente el mapa de vesselness en
# "vaso"/"fondo" maximizando la varianza ENTRE las dos clases.
# ==============================================================================

function _umbral_otsu(valores::Vector{Float64})
    minv, maxv = extrema(valores)
    if maxv <= minv
        return minv
    end

    nbins = 256
    hist = zeros(Int, nbins)
    escala = (nbins - 1) / (maxv - minv)
    for v in valores
        bin = clamp(round(Int, (v - minv) * escala) + 1, 1, nbins)
        hist[bin] += 1
    end

    total = length(valores)
    suma_total = sum((b - 1) * hist[b] for b in 1:nbins)

    suma_acum = 0.0
    peso_fondo = 0
    mejor_var = -1.0
    mejor_bin = 1

    for b in 1:nbins
        peso_fondo += hist[b]
        peso_fondo == 0 && continue
        peso_vaso = total - peso_fondo
        peso_vaso == 0 && break

        suma_acum += (b - 1) * hist[b]
        media_fondo = suma_acum / peso_fondo
        media_vaso = (suma_total - suma_acum) / peso_vaso

        var_entre = peso_fondo * peso_vaso * (media_fondo - media_vaso)^2
        if var_entre > mejor_var
            mejor_var = var_entre
            mejor_bin = b
        end
    end

    return minv + (mejor_bin - 1) / escala
end

# ==============================================================================
# LECTURA DE VOLUMEN Y RECORTE POR BBOX (delimitación hepática — Paso 0
# del diseño). El recorte manual (si se da `bbox`) sí está implementado;
# el aislamiento AUTOMÁTICO del hígado todavía no — ver nota en
# docs/CAMBIOS_PARA_GRAFOS.md sobre por qué (un Otsu + componente conexa
# sobre el volumen completo NO aísla el hígado específicamente, solo
# separa "tejido" de "fondo/aire"; hacerlo bien requiere un método que
# distinga órganos, no solo intensidad).
# ==============================================================================

function _leer_volumen_generico(filepath::AbstractString)
    tipo = detectar_tipo_archivo(filepath)
    if tipo == :unknown
        error("Formato no soportado: $filepath")
    elseif tipo == :nifti
        volumen, voxel_dims = leer_volumen_nifti(filepath)
    else
        volumen, voxel_dims = leer_volumen_dicom(filepath)
    end
    volumen = map(v -> isfinite(v) ? Float64(v) : 0.0, volumen)
    return volumen, voxel_dims
end

"""`bbox` = `[x0,x1,y0,y1,z0,z1]`, 1-indexado, inclusivo. `nothing` -> sin recorte."""
function _recortar_bbox(vol::Array{Float64,3}, bbox)
    isnothing(bbox) && return vol
    x0, x1, y0, y1, z0, z1 = bbox
    nx, ny, nz = size(vol)
    x0 = clamp(Int(x0), 1, nx); x1 = clamp(Int(x1), 1, nx)
    y0 = clamp(Int(y0), 1, ny); y1 = clamp(Int(y1), 1, ny)
    z0 = clamp(Int(z0), 1, nz); z1 = clamp(Int(z1), 1, nz)
    return vol[min(x0, x1):max(x0, x1), min(y0, y1):max(y0, y1), min(z0, z1):max(z0, z1)]
end

# ==============================================================================
# PIPELINE POR ARCHIVO (Fase 1 completa: leer -> recortar -> vesselness
# -> binarizar -> empaquetar resultado + imágenes de validación visual)
# ==============================================================================

function _analizar_grafo_vascular(archivo::AbstractString, opciones)
    nombre_archivo = basename(archivo)
    try
        if !isfile(archivo)
            return Dict("archivo" => nombre_archivo, "success" => false, "error" => "Archivo no encontrado")
        end

        volumen, voxel_dims = _leer_volumen_generico(archivo)

        bbox = get(opciones, "bbox", nothing)
        origen_region = isnothing(bbox) ?
            "volumen completo (sin recorte — el aislamiento automático del hígado todavía no está implementado, ver docs/CAMBIOS_PARA_GRAFOS.md)" :
            "bbox manual"
        volumen = _recortar_bbox(volumen, bbox)

        if isempty(volumen) || all(iszero, volumen)
            return Dict("archivo" => nombre_archivo, "success" => false, "error" => "Volumen vacío tras el recorte (revisar bbox)")
        end

        escalas_mm = Float64[Float64(s) for s in get(opciones, "escalas_mm", [1.0, 2.0, 3.0])]
        alpha = Float64(get(opciones, "alpha", 0.5))
        beta = Float64(get(opciones, "beta", 0.5))
        c_opt = get(opciones, "c", nothing)
        c_override = isnothing(c_opt) ? nothing : Float64(c_opt)

        vesselness = calcular_vesselness(volumen, voxel_dims;
                                          escalas_mm=escalas_mm, alpha=alpha, beta=beta, c_override=c_override)

        umbral_opt = get(opciones, "umbral_vesselness", nothing)
        umbral = isnothing(umbral_opt) ? _umbral_otsu(vec(vesselness)) : Float64(umbral_opt)
        origen_umbral = isnothing(umbral_opt) ? "automatico (Otsu)" : "manual"

        mascara = vesselness .> umbral
        n_vasculares = count(mascara)

        # Validación visual: corte axial central, volumen original vs. máscara detectada.
        indice_corte = max(1, size(volumen, 3) ÷ 2)
        corte_original = extract_slice(volumen, "axial", indice_corte)
        corte_mascara = extract_slice(Float64.(mascara), "axial", indice_corte)

        return Dict(
            "archivo" => nombre_archivo,
            "success" => true,
            "voxel_dims_mm" => collect(voxel_dims),
            "region" => Dict("bbox_usado" => bbox, "origen" => origen_region),
            "deteccion_vascular" => Dict(
                "escalas_mm" => escalas_mm,
                "umbral_vesselness" => umbral,
                "origen_umbral" => origen_umbral,
                "voxeles_vasculares" => n_vasculares,
                "fraccion_volumen" => n_vasculares / length(mascara),
            ),
            "visualizacion" => Dict(
                "indice_corte_axial" => indice_corte,
                "corte_original_png" => matrix_to_base64_png(corte_original),
                "corte_mascara_png" => matrix_to_base64_png(corte_mascara),
            ),
            "fase_pipeline" => "Fase 1: realce vascular (Frangi) + binarización. La esqueletización y " *
                                "la extracción del grafo (Fase 2) todavía no están implementadas — " *
                                "todavía no hay nodos/aristas/métricas de grafo para este archivo.",
        )
    catch e
        println("    ❌ Error procesando $nombre_archivo: $e")
        return Dict("archivo" => nombre_archivo, "success" => false, "error" => string(e))
    end
end

# ==============================================================================
# PUNTO DE ENTRADA DEL MÓDULO
# ==============================================================================

"""
    analizar_grafos(archivos, tipo_grafo, opciones; on_progreso) -> Dict

`opciones` (sin tipar `Dict`: llega tal cual del handler, puede ser un
`JSON3.Object`, igual que `grupos` en `analizar_estadistico`) acepta:
`"bbox"`, `"escalas_mm"`, `"alpha"`, `"beta"`, `"c"`, `"umbral_vesselness"`
— todos opcionales, con defaults razonables si se omiten.

`on_progreso`, si se da, es `(completados::Int, total::Int) -> nothing`
— mismo contrato que en `analizar_radiomico`.
"""
function analizar_grafos(archivos::Vector{String}, tipo_grafo::AbstractString, opciones;
                          on_progreso::Union{Function,Nothing}=nothing)
    if tipo_grafo == "conectividad"
        return Dict(
            "success" => false,
            "error" => "Grafos de conectividad (series temporales) todavía no está implementado. " *
                       "Requiere lectura de volúmenes 4D, no soportada aún por ProcesamientoImagenes.jl.",
        )
    elseif tipo_grafo != "vascular"
        return Dict("success" => false, "error" => "tipo_grafo desconocido: '$tipo_grafo' (esperado 'vascular' o 'conectividad')")
    end

    total = length(archivos)
    resultados = Vector{Dict}()

    for (i, archivo) in enumerate(archivos)
        println("  🕸️  Procesando: $(basename(archivo))")
        push!(resultados, _analizar_grafo_vascular(archivo, opciones))
        if !isnothing(on_progreso)
            on_progreso(i, total)
        end
    end

    return Dict(
        "success" => true,
        "tipo_grafo" => tipo_grafo,
        "resultados" => resultados,
    )
end

"""
Guarda los resultados en un Excel, una fila por archivo. Mismo patrón que
`guardar_resultados_radiomicos_excel`/`guardar_resultados_estadisticos_excel`.
Las imágenes de validación NO se escriben acá (viven en la respuesta JSON
para el frontend) — en una hoja de cálculo solo aportarían peso.
"""
function guardar_resultados_grafos_excel(result::Dict, base_resultados::String)
    dir_resultados = joinpath(base_resultados, "grafos")
    mkpath(dir_resultados)

    timestamp = Dates.format(now(), "yyyymmdd_HHMMSS")
    ruta_completa = joinpath(dir_resultados, "grafos_$(timestamp).xlsx")

    resultados = get(result, "resultados", [])

    XLSX.openxlsx(ruta_completa, mode="w") do xf
        sheet = xf[1]
        XLSX.rename!(sheet, "Grafos")

        encabezados = ["Archivo", "Estado", "Vóxeles vasculares", "Fracción de volumen",
                       "Umbral vesselness", "Origen umbral", "Escalas (mm)", "Región", "Fase / nota"]
        for (col, encabezado) in enumerate(encabezados)
            sheet[XLSX.CellRef(1, col)] = encabezado
        end

        for (fila_idx, r) in enumerate(resultados)
            fila = fila_idx + 1
            d = get(r, "deteccion_vascular", Dict())
            sheet[XLSX.CellRef(fila, 1)] = get(r, "archivo", "")
            sheet[XLSX.CellRef(fila, 2)] = get(r, "success", false) ? "Completado" : "Error"
            sheet[XLSX.CellRef(fila, 3)] = get(d, "voxeles_vasculares", get(r, "error", ""))
            sheet[XLSX.CellRef(fila, 4)] = get(d, "fraccion_volumen", "")
            sheet[XLSX.CellRef(fila, 5)] = get(d, "umbral_vesselness", "")
            sheet[XLSX.CellRef(fila, 6)] = get(d, "origen_umbral", "")
            sheet[XLSX.CellRef(fila, 7)] = join(get(d, "escalas_mm", []), ", ")
            sheet[XLSX.CellRef(fila, 8)] = get(get(r, "region", Dict()), "origen", "")
            sheet[XLSX.CellRef(fila, 9)] = get(r, "fase_pipeline", get(r, "error", ""))
        end
    end

    println("📊 Excel guardado: $ruta_completa")
    return ruta_completa
end
