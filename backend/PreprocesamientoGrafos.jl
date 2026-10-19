# ==============================================================================
# PreprocesamientoGrafos.jl — Preprocesamiento de imágenes para el módulo de
# grafos: de un volumen de RM (NIfTI/DICOM) a una MÁSCARA VASCULAR BINARIA.
# ==============================================================================
#
# Este archivo está separado de AnalisisGrafos.jl a propósito: el
# preprocesamiento es la parte que más va a cambiar (segmentación del hígado,
# distinción hígado/hueso, nuevos filtros o pasos, quizá herramientas externas
# como Python), mientras que el análisis (esqueleto, grafo, métricas) es más
# estable. El contrato entre los dos es UNA función:
#
#     preprocesar_volumen_grafos(archivo, opciones)
#         -> (mascara::Array{Bool,3}, volumen::Array{Float64,3},
#             voxel_dims::NTuple{3,Float64}, info::Dict)
#
#   - `mascara`    : vaso/no-vaso, ya limpia, sobre el volumen (recortado si
#                    hubo `bbox`). Es lo único que consume AnalisisGrafos.jl.
#   - `volumen`    : el volumen sobre el que se calculó (para mostrarlo).
#   - `voxel_dims` : espaciado en mm (x, y, z).
#   - `info`       : metadatos para el resultado (región usada, umbral, conteos).
#
# Mientras `preprocesar_volumen_grafos` siga devolviendo eso, se puede
# reescribir todo lo que hay adentro sin tocar AnalisisGrafos.jl.
#
# Pasos actuales (en orden): leer -> recortar por bbox (opcional) -> realce
# vascular (Frangi 3D multi-escala) -> umbral (Otsu o fijo) -> quitar
# componentes pequeñas -> rellenar cavidades internas.
#
# Limitación conocida: NO hay aislamiento del hígado. El filtro de Frangi
# responde a cualquier estructura brillante y alargada (vasos, pero también
# médula ósea, bordes, etc.), así que sin delimitar el hígado la máscara
# incluye cosas que no son vasos hepáticos. Sobre tubos sintéticos (vóxel
# isotrópico y anisotrópico) el filtro da 100% de cobertura del eje y 0% de
# falsos positivos (`autoprueba_preprocesamiento`): el problema no es el filtro
# sino lo que se le da a analizar. Solo detecta estructuras BRILLANTES sobre
# fondo oscuro. Ver docs/CAMBIOS_PARA_GRAFOS.md.
#
# Opciones que consume este archivo (todas opcionales, en `opciones`):
#   "bbox"                  [x0,x1,y0,y1,z0,z1], 1-indexado inclusivo
#   "escalas_mm"            σ del filtro, en mm (default [1.0, 2.0, 3.0])
#   "alpha", "beta", "c"    parámetros de Frangi (default 0.5, 0.5, adaptativo)
#   "umbral_vesselness"     umbral fijo (default: Otsu automático)
#   "min_voxeles_componente" componentes con menos vóxeles se descartan (default 100)
#   "rellenar_cavidades"    true/false (default true)
#
# Reutiliza los lectores de AnalisisRadiomico.jl (`detectar_tipo_archivo`,
# `leer_volumen_nifti`, `leer_volumen_dicom`), ya cargados en `Main`.
# ==============================================================================

import LinearAlgebra   # solo para la autoprueba (comparar eigenvalores)

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

Las derivadas se calculan en UNIDADES FÍSICAS (intensidad/mm²): cada
diferencia se divide por el espaciado de vóxel (`h_i²` en las derivadas puras,
`4·h_i·h_j` en las mixtas, donde el 4 es de la diferencia centrada). Es
necesario cuando el vóxel es anisotrópico (p. ej. 1×1×3 mm): con diferencias en
índices de vóxel la Hessiana real `H` se convierte en `D·H·D` con
`D = diag(h)`, que no es un cambio de escala uniforme y deforma los cocientes
de autovalores que usa Frangi (un tubo que corre en el plano, con sus dos
direcciones transversales ponderadas 1 y 9, se leería como una placa). Con
vóxeles isotrópicos de 1 mm el resultado es idéntico al anterior.
"""
function _hessiana_3d(vol::Array{Float64,3}, voxel_dims)
    nx, ny, nz = size(vol)
    sx, sy, sz = Float64(voxel_dims[1]), Float64(voxel_dims[2]), Float64(voxel_dims[3])
    wxx = 1 / sx^2; wyy = 1 / sy^2; wzz = 1 / sz^2
    wxy = 1 / (4 * sx * sy); wxz = 1 / (4 * sx * sz); wyz = 1 / (4 * sy * sz)
    Ixx = similar(vol); Iyy = similar(vol); Izz = similar(vol)
    Ixy = similar(vol); Ixz = similar(vol); Iyz = similar(vol)

    @inbounds Threads.@threads for k in 1:nz
        kp = clamp(k + 1, 1, nz); km = clamp(k - 1, 1, nz)
        for j in 1:ny
            jp = clamp(j + 1, 1, ny); jm = clamp(j - 1, 1, ny)
            for i in 1:nx
                ip = clamp(i + 1, 1, nx); im = clamp(i - 1, 1, nx)
                c = vol[i, j, k]

                Ixx[i, j, k] = (vol[ip, j, k] - 2c + vol[im, j, k]) * wxx
                Iyy[i, j, k] = (vol[i, jp, k] - 2c + vol[i, jm, k]) * wyy
                Izz[i, j, k] = (vol[i, j, kp] - 2c + vol[i, j, km]) * wzz

                Ixy[i, j, k] = (vol[ip, jp, k] - vol[ip, jm, k] - vol[im, jp, k] + vol[im, jm, k]) * wxy
                Ixz[i, j, k] = (vol[ip, j, kp] - vol[ip, j, km] - vol[im, j, kp] + vol[im, j, km]) * wxz
                Iyz[i, j, k] = (vol[i, jp, kp] - vol[i, jp, km] - vol[i, jm, kp] + vol[i, jm, km]) * wyz
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
    Ixx, Iyy, Izz, Ixy, Ixz, Iyz = _hessiana_3d(suavizado, voxel_dims)

    # Normalización de escala (Lindeberg, γ=2): sin esto, un σ más grande
    # da respuestas sistemáticamente más chicas aunque el vaso de ese
    # calibre sí esté presente — esto iguala la comparación entre escalas.
    # Con la Hessiana en intensidad/mm², σ² la deja en unidades de intensidad
    # (las mismas de `c` manual y de la "fuerza de estructura" S).
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

# --- utilidades de indexado ----------------------------------------------------

"""(i,j,k) 1-indexado de un índice lineal de un arreglo de tamaño (mx,my,·)."""
@inline function _ijk(idx::Int, mx::Int, my::Int)
    r = idx - 1
    k = r ÷ (mx * my) + 1
    r2 = r % (mx * my)
    j = r2 ÷ mx + 1
    i = r2 % mx + 1
    return i, j, k
end

# --- limpieza de la máscara ----------------------------------------------------

"""
Quita las componentes 26-conexas de la máscara con menos de `min_vox`
vóxeles (motas de ruido). Devuelve `(mascara_limpia, n_antes, n_despues)`.
"""
function _filtrar_componentes_pequenas(mascara::Array{Bool,3}, min_vox::Int)
    nx, ny, nz = size(mascara)
    visitado = zeros(Bool, nx, ny, nz)
    resultado = zeros(Bool, nx, ny, nz)
    pila = Int[]
    comp = Int[]
    n_antes = 0
    n_despues = 0

    for idx0 in eachindex(mascara)
        (mascara[idx0] && !visitado[idx0]) || continue
        empty!(pila); empty!(comp)
        push!(pila, idx0)
        visitado[idx0] = true
        while !isempty(pila)
            idx = pop!(pila)
            push!(comp, idx)
            i, j, k = _ijk(idx, nx, ny)
            for dk in -1:1, dj in -1:1, di in -1:1
                (di == 0 && dj == 0 && dk == 0) && continue
                a = i + di; b = j + dj; c = k + dk
                (a < 1 || a > nx || b < 1 || b > ny || c < 1 || c > nz) && continue
                nidx = a + (b - 1) * nx + (c - 1) * nx * ny
                if mascara[nidx] && !visitado[nidx]
                    visitado[nidx] = true
                    push!(pila, nidx)
                end
            end
        end
        n_antes += 1
        if length(comp) >= min_vox
            n_despues += 1
            for idx in comp
                resultado[idx] = true
            end
        end
    end
    return resultado, n_antes, n_despues
end

"""
Rellena las cavidades internas de la máscara: todo el fondo (6-conexo) que
NO está conectado con el exterior del volumen pasa a ser vaso. Un agujero
dentro de un vaso (ruido) haría que el adelgazamiento conserve una "cáscara"
alrededor de él — topológicamente correcto, pero espurio para un árbol
vascular.
"""
function _rellenar_cavidades(mascara::Array{Bool,3})
    nx, ny, nz = size(mascara)
    mx, my, mz = nx + 2, ny + 2, nz + 2
    P = zeros(Bool, mx, my, mz)
    P[2:nx+1, 2:ny+1, 2:nz+1] .= mascara
    exterior = zeros(Bool, mx, my, mz)
    pila = Int[1]
    exterior[1] = true
    while !isempty(pila)
        idx = pop!(pila)
        i, j, k = _ijk(idx, mx, my)
        for (di, dj, dk) in ((1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1))
            a = i + di; b = j + dj; c = k + dk
            (a < 1 || a > mx || b < 1 || b > my || c < 1 || c > mz) && continue
            if !P[a, b, c] && !exterior[a, b, c]
                exterior[a, b, c] = true
                push!(pila, a + (b - 1) * mx + (c - 1) * mx * my)
            end
        end
    end
    resultado = zeros(Bool, nx, ny, nz)
    for k in 1:nz, j in 1:ny, i in 1:nx
        resultado[i, j, k] = !exterior[i+1, j+1, k+1]
    end
    return resultado
end


# ==============================================================================
# PUNTO DE ENTRADA DEL PREPROCESAMIENTO
# ==============================================================================

"""
    preprocesar_volumen_grafos(archivo, opciones) -> (mascara, volumen, voxel_dims, info)

Ver el contrato en la cabecera de este archivo. Lanza una excepción si el
archivo no se puede leer o si el volumen queda vacío tras el recorte; el
llamador (`_analizar_grafo_vascular`, en AnalisisGrafos.jl) la convierte en un
resultado `success=false` para ese archivo.

`info["deteccion_vascular"]["voxeles_vasculares"]` y `["fraccion_volumen"]`
se refieren a la máscara FINAL (ya limpia); los conteos intermedios
(`voxeles_vasculares_crudos`, `componentes_antes`, `componentes_despues`,
`voxeles_cavidades_rellenadas`) dejan ver qué hizo cada paso de limpieza.
"""
function preprocesar_volumen_grafos(archivo::AbstractString, opciones)
    volumen, voxel_dims = _leer_volumen_generico(archivo)

    bbox = get(opciones, "bbox", nothing)
    origen_region = isnothing(bbox) ? "volumen completo (sin recorte)" : "bbox manual"
    volumen = _recortar_bbox(volumen, bbox)

    if isempty(volumen) || all(iszero, volumen)
        error("Volumen vacío tras el recorte (revisar bbox)")
    end

    # 1) Realce vascular (Frangi) + umbral.
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

    mascara_cruda = Array{Bool,3}(vesselness .> umbral)
    n_cruda = count(mascara_cruda)

    # 2) Limpieza de la máscara.
    min_vox = Int(get(opciones, "min_voxeles_componente", 100))
    mascara, comp_antes, comp_despues = _filtrar_componentes_pequenas(mascara_cruda, min_vox)
    n_tras_filtro = count(mascara)

    if Bool(get(opciones, "rellenar_cavidades", true))
        mascara = _rellenar_cavidades(mascara)
    end
    n_final = count(mascara)

    info = Dict{String,Any}(
        "voxel_dims_mm" => collect(voxel_dims),
        "region" => Dict{String,Any}("bbox_usado" => bbox, "origen" => origen_region),
        "deteccion_vascular" => Dict{String,Any}(
            "escalas_mm" => escalas_mm,
            "umbral_vesselness" => umbral,
            "origen_umbral" => origen_umbral,
            "voxeles_vasculares_crudos" => n_cruda,
            "componentes_antes" => comp_antes,
            "componentes_despues" => comp_despues,
            "voxeles_cavidades_rellenadas" => n_final - n_tras_filtro,
            "voxeles_vasculares" => n_final,
            "fraccion_volumen" => n_final / length(mascara),
        ),
    )
    return mascara, volumen, voxel_dims, info
end

# ==============================================================================
# AUTOPRUEBA — casos con respuesta conocida, sin necesitar archivos reales.
#   julia --project=. -e 'include("PreprocesamientoGrafos.jl"); autoprueba_preprocesamiento()'
# (se puede correr suelto: este archivo no depende de nada más al cargarse).
# ==============================================================================

function autoprueba_preprocesamiento()
    ok = true
    chequear = function (nombre, cond)
        println(cond ? "  ✅ " : "  ❌ ", nombre)
        return cond
    end
    println("Autoprueba del preprocesamiento para grafos")

    # Generador pseudoaleatorio determinista (congruencial lineal), sin depender de Random.
    estado = UInt64(12345)
    azar = function ()
        estado = estado * 6364136223846793005 + 1442695040888963407
        return Float64(estado >> 11) / Float64(UInt64(1) << 53) * 2 - 1
    end

    # 1) Eigenvalores en forma cerrada = LinearAlgebra.
    peor = 0.0
    for _ in 1:2000
        a11 = azar(); a22 = azar(); a33 = azar(); a12 = azar(); a13 = azar(); a23 = azar()
        A = [a11 a12 a13; a12 a22 a23; a13 a23 a33]
        ref = LinearAlgebra.eigvals(LinearAlgebra.Symmetric(A))
        e1, e2, e3 = _eigenvalores_sim_3x3(a11, a22, a33, a12, a13, a23)
        peor = max(peor, maximum(abs.(sort([e1, e2, e3]) .- ref)))
    end
    ok &= chequear("eigenvalores en forma cerrada = LinearAlgebra (peor diferencia $(peor))", peor < 1e-9)

    # 2) Otsu separa dos grupos.
    u = _umbral_otsu(vcat(fill(0.05, 900), fill(0.95, 100)))
    ok &= chequear("Otsu: el umbral cae entre los dos grupos ($(u))", 0.05 <= u < 0.95)

    # 3) Filtro de componentes pequeñas.
    m = zeros(Bool, 20, 20, 20)
    m[2:4, 2:4, 2:4] .= true          # 27 vóxeles
    m[10:17, 10:17, 10:17] .= true    # 512 vóxeles
    m[19, 19, 19] = true              # 1 vóxel
    f, antes, despues = _filtrar_componentes_pequenas(m, 50)
    ok &= chequear("filtro de componentes: 3 -> 1, conserva solo la grande", antes == 3 && despues == 1 && count(f) == 512)

    # 4) Relleno de cavidades: rellena la cerrada, no la abierta al exterior.
    c = zeros(Bool, 20, 20, 20)
    c[5:15, 5:15, 5:15] .= true
    c[9:11, 9:11, 9:11] .= false
    ok &= chequear("relleno de cavidades: rellena una cavidad cerrada", count(_rellenar_cavidades(c)) == 11^3)
    c2 = copy(c)
    c2[9:11, 9:11, 5:8] .= false      # túnel hacia el exterior: ya no es cavidad cerrada
    ok &= chequear("relleno de cavidades: no toca una cavidad abierta al exterior", count(_rellenar_cavidades(c2)) == count(c2))

    # 5) Frangi + Otsu sobre un tubo brillante sintético.
    forma = (30, 30, 40)
    tubo = zeros(Float64, forma...)
    for k in 1:forma[3], j in 1:forma[2], i in 1:forma[1]
        sqrt((i - 16.0)^2 + (j - 16.0)^2) <= 3.0 && (tubo[i, j, k] = 1.0)
    end
    suave = suavizar_gaussiano_3d(tubo, 0.6, 0.6, 0.6)
    v = calcular_vesselness(suave, (1.0, 1.0, 1.0))
    umbral = _umbral_otsu(vec(v))
    n_eje = 0; en_eje = 0; n_lejos = 0; en_lejos = 0
    for k in 1:forma[3], j in 1:forma[2], i in 1:forma[1]
        d = sqrt((i - 16.0)^2 + (j - 16.0)^2)
        if d <= 1.0
            n_eje += 1
            v[i, j, k] > umbral && (en_eje += 1)
        elseif d >= 8.0
            n_lejos += 1
            v[i, j, k] > umbral && (en_lejos += 1)
        end
    end
    ok &= chequear("Frangi + Otsu: cobertura del eje del tubo $(round(100 * en_eje / n_eje; digits=1))% (>= 95%)", en_eje / n_eje >= 0.95)
    ok &= chequear("Frangi + Otsu: falsos positivos lejos del tubo $(round(100 * en_lejos / n_lejos; digits=2))% (<= 1%)", en_lejos / n_lejos <= 0.01)

    # 6) Vóxel anisotrópico (1,1,3) mm: un tubo que corre en el plano y otro entre cortes, ambos de
    #    radio 3 mm, deben dar una respuesta alta. Con la Hessiana en índices de vóxel el del plano
    #    llegaba a ~0.06 (y el otro a ~0.11); con la Hessiana en mm: ~0.48 y ~0.75.
    forma_a = (36, 36, 24)
    dims_a = (1.0, 1.0, 3.0)
    vol_a = zeros(Float64, forma_a...)
    dist_a = zeros(Float64, forma_a...)      # distancia al eje del tubo A (a lo largo de x, en el plano)
    dist_b = zeros(Float64, forma_a...)      # distancia al eje del tubo B (a lo largo de z, entre cortes)
    for k in 1:forma_a[3], j in 1:forma_a[2], i in 1:forma_a[1]
        px = (i - 1) * dims_a[1]; py = (j - 1) * dims_a[2]; pz = (k - 1) * dims_a[3]
        da = sqrt((py - 9.0)^2 + (pz - 34.5)^2)
        db = sqrt((px - 26.0)^2 + (py - 26.0)^2)
        dist_a[i, j, k] = da
        dist_b[i, j, k] = db
        (da <= 3.0 || db <= 3.0) && (vol_a[i, j, k] = 1.0)
    end
    va = calcular_vesselness(vol_a, dims_a)
    vmax_a = maximum(va[dist_a .<= 1.6])
    vmax_b = maximum(va[dist_b .<= 1.6])
    ok &= chequear("vóxel anisotrópico: vesselness del tubo en el plano $(round(vmax_a; digits=3)) y entre cortes $(round(vmax_b; digits=3)) (ambos >= 0.3)",
                   vmax_a >= 0.3 && vmax_b >= 0.3)

    println(ok ? "✅ Autoprueba del preprocesamiento: todo en orden" : "❌ Autoprueba del preprocesamiento: HAY FALLOS")
    return ok
end
