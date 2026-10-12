# ==============================================================================
# AnalisisGrafos.jl — Módulo de dominio: análisis por grafos (4º módulo)
# ==============================================================================
#
# FASE 2: de la máscara vascular binaria al GRAFO. Pasos de este archivo:
#   distancia al fondo (radio local) -> esqueleto (línea central) -> grafo
#   (nodos = puntas/bifurcaciones, aristas = segmentos) -> poda de ramas
#   espurias -> métricas básicas -> JSON del grafo + imágenes de validación.
#
# La obtención de la máscara (lectura del volumen, realce vascular, umbral,
# limpieza) NO vive acá: está en PreprocesamientoGrafos.jl, que se espera que
# cambie bastante. Este archivo solo la consume a través de
# `preprocesar_volumen_grafos(archivo, opciones)` (ver ese contrato) — así
# se puede reescribir el preprocesamiento sin tocar nada de lo de abajo.
# También usa `extract_slice` y `matrix_to_base64_png` de
# ProcesamientoImagenes.jl (ambos ya cargados en `Main`; ver orden de
# `include` en server.jl).
#
# Dispatch por `tipo_grafo` (mismo patrón que `tipo_datos` en
# AnalisisEstadistico.jl): "vascular" (esta fase) vs "conectividad"
# (reservado, el handler lo rechaza con 501 antes de llegar acá).
#
# Estos algoritmos se escribieron y verificaron primero en un prototipo de
# referencia en Python (docs/referencia/prototipo_fase2.py) sobre fantomas con
# respuesta conocida; este código Julia es el port de esa misma lógica.
# `autoprueba_grafos()` (al final) repite los fantomas clave y se puede correr
# suelta, sin archivos de imagen:
#
#   julia --project=. -e 'include("AnalisisGrafos.jl"); autoprueba_grafos()'
#
# Opciones que consume este archivo (todas opcionales, en `opciones`; las de
# preprocesamiento están listadas en PreprocesamientoGrafos.jl):
#   "longitud_min_rama_mm"  poda: largo mínimo de una rama terminal (default 3.0)
#   "factor_radio_poda"     poda: ... o este múltiplo del radio de la rama más
#                           gruesa de su bifurcación, lo que sea mayor (default 1.5)
#   "ventana_suavizado"     semiventana (en vóxeles de camino) del suavizado de
#                           la línea central antes de medir su longitud (default 2)
# ==============================================================================

using Dates
using XLSX
using JSON3

# (i,j,k) 1-indexado de un índice lineal de un arreglo de tamaño (mx,my,·).
@inline function _ijk_grafo(idx::Int, mx::Int, my::Int)
    r = idx - 1
    k = r ÷ (mx * my) + 1
    r2 = r % (mx * my)
    j = r2 ÷ mx + 1
    i = r2 % mx + 1
    return i, j, k
end

# --- transformada de distancia euclidiana exacta (Felzenszwalb-Huttenlocher) ----
#
# Para cada vóxel de vaso: distancia (en mm, respetando el espaciado
# anisotrópico) al vóxel de fondo más cercano. Sobre el esqueleto, esa
# distancia es una estimación del RADIO local del vaso; además ordena el
# adelgazamiento (se pela de afuera hacia adentro).

const _EDT_GRANDE = 1e20

function _edt_1d!(d::Vector{Float64}, f::Vector{Float64}, h::Float64, v::Vector{Int}, z::Vector{Float64})
    n = length(f)
    k = 1
    v[1] = 1
    z[1] = -Inf
    z[2] = Inf
    for q in 2:n
        xq = (q - 1) * h
        s = 0.0
        while true
            xv = (v[k] - 1) * h
            s = ((f[q] + xq * xq) - (f[v[k]] + xv * xv)) / (2 * xq - 2 * xv)
            if s <= z[k]
                k -= 1
            else
                break
            end
        end
        k += 1
        v[k] = q
        z[k] = s
        z[k+1] = Inf
    end
    k = 1
    for q in 1:n
        xq = (q - 1) * h
        while z[k+1] < xq
            k += 1
        end
        xv = (v[k] - 1) * h
        d[q] = (xq - xv)^2 + f[v[k]]
    end
    return nothing
end

function _edt_pasada!(f::Array{Float64,3}, eje::Int, h::Float64)
    nx, ny, nz = size(f)
    n = size(f, eje)
    if eje == 1
        Threads.@threads for k in 1:nz
            lin = Vector{Float64}(undef, n); d = Vector{Float64}(undef, n)
            v = Vector{Int}(undef, n); z = Vector{Float64}(undef, n + 1)
            for j in 1:ny
                for i in 1:nx; lin[i] = f[i, j, k]; end
                _edt_1d!(d, lin, h, v, z)
                for i in 1:nx; f[i, j, k] = d[i]; end
            end
        end
    elseif eje == 2
        Threads.@threads for k in 1:nz
            lin = Vector{Float64}(undef, n); d = Vector{Float64}(undef, n)
            v = Vector{Int}(undef, n); z = Vector{Float64}(undef, n + 1)
            for i in 1:nx
                for j in 1:ny; lin[j] = f[i, j, k]; end
                _edt_1d!(d, lin, h, v, z)
                for j in 1:ny; f[i, j, k] = d[j]; end
            end
        end
    else
        Threads.@threads for j in 1:ny
            lin = Vector{Float64}(undef, n); d = Vector{Float64}(undef, n)
            v = Vector{Int}(undef, n); z = Vector{Float64}(undef, n + 1)
            for i in 1:nx
                for k in 1:nz; lin[k] = f[i, j, k]; end
                _edt_1d!(d, lin, h, v, z)
                for k in 1:nz; f[i, j, k] = d[k]; end
            end
        end
    end
    return nothing
end

"""Distancia (mm) de cada vóxel de `mascara` al fondo más cercano; 0 en el fondo."""
function _transformada_distancia(mascara::Array{Bool,3}, voxel_dims)
    f = Array{Float64,3}(undef, size(mascara))
    for idx in eachindex(mascara)
        f[idx] = mascara[idx] ? _EDT_GRANDE : 0.0
    end
    for eje in 1:3
        _edt_pasada!(f, eje, Float64(voxel_dims[eje]))
    end
    tope = maximum(Float64.(collect(size(mascara))) .* Float64.(collect(voxel_dims)))
    for idx in eachindex(f)
        f[idx] = f[idx] >= 1e19 ? tope : sqrt(f[idx])   # máscara sin fondo alguno: distancia acotada
    end
    return f
end

# --- adelgazamiento topológico (puntos simples, Bertrand-Malandain) -------------
#
# Un vóxel de la máscara es "simple" si quitarlo no cambia la topología
# (no parte el objeto en dos, no abre ni cierra un túnel, no crea ni
# elimina una cavidad). Con conectividad 26 para el objeto y 6 para el fondo:
#   simple  <=>  T26(x, objeto) = 1  y  T6+(x, fondo) = 1
# donde T26 cuenta las componentes 26-conexas del objeto en la vecindad
# 3x3x3 (sin el centro), y T6+ cuenta las componentes 6-conexas del fondo
# en la vecindad de 18 que tocan una cara del centro. La vecindad se
# representa como 27 bits, y las componentes se cuentan con aritmética de
# bits (sin asignar memoria en el lazo caliente).

@inline _oidx(dx::Int, dy::Int, dz::Int) = (dx + 1) * 9 + (dy + 1) * 3 + (dz + 1)

const _OFFS = [(dx, dy, dz) for dx in -1:1 for dy in -1:1 for dz in -1:1]

function _tabla_adyacencia(manhattan::Bool)
    t = zeros(UInt32, 27)
    for a in _OFFS, b in _OFFS
        (a == b || a == (0, 0, 0) || b == (0, 0, 0)) && continue
        cheb = max(abs(a[1] - b[1]), abs(a[2] - b[2]), abs(a[3] - b[3]))
        manh = abs(a[1] - b[1]) + abs(a[2] - b[2]) + abs(a[3] - b[3])
        if (manhattan && manh == 1) || (!manhattan && cheb == 1)
            t[_oidx(a[1], a[2], a[3]) + 1] |= UInt32(1) << _oidx(b[1], b[2], b[3])
        end
    end
    return t
end

function _mascara_bits(pred)
    m = UInt32(0)
    for o in _OFFS
        o == (0, 0, 0) && continue
        s = abs(o[1]) + abs(o[2]) + abs(o[3])
        if pred(s)
            m |= UInt32(1) << _oidx(o[1], o[2], o[3])
        end
    end
    return m
end

const _ADJ26 = _tabla_adyacencia(false)
const _ADJ6 = _tabla_adyacencia(true)
const _MASK26 = _mascara_bits(s -> true)
const _MASK18 = _mascara_bits(s -> s <= 2)
const _FACE = _mascara_bits(s -> s == 1)

@inline function _vecindad_bits(P::Array{Bool,3}, i::Int, j::Int, k::Int)
    bits = UInt32(0)
    @inbounds for dz in -1:1, dy in -1:1, dx in -1:1
        if (dx != 0 || dy != 0 || dz != 0) && P[i+dx, j+dy, k+dz]
            bits |= UInt32(1) << _oidx(dx, dy, dz)
        end
    end
    return bits
end

"""Componentes (según la tabla de adyacencia `adj`) del conjunto de bits; si
`cond != 0`, solo cuenta las que contienen algún bit de `cond`."""
@inline function _contar_componentes(bits::UInt32, adj::Vector{UInt32}, cond::UInt32)
    resto = bits
    n = 0
    while resto != 0
        semilla = resto & (~resto + one(UInt32))
        comp = semilla
        frontera = semilla
        while frontera != 0
            b = trailing_zeros(frontera)
            frontera &= frontera - one(UInt32)
            nuevos = adj[b+1] & resto & ~comp
            comp |= nuevos
            frontera |= nuevos
        end
        resto &= ~comp
        if cond == 0 || (comp & cond) != 0
            n += 1
        end
    end
    return n
end

@inline function _es_simple(fg::UInt32)
    _contar_componentes(fg & _MASK26, _ADJ26, UInt32(0)) != 1 && return false
    bg = (~fg) & _MASK18
    return _contar_componentes(bg, _ADJ6, _FACE) == 1
end

"""
Esqueleto (línea central) de la máscara por adelgazamiento: en rondas, se
borran los vóxeles de borde que son puntos simples, del más cercano al
fondo (menor distancia) al más profundo, conservando siempre las puntas
(vóxeles con un único vecino) para no acortar las ramas hasta un punto.
Termina cuando una ronda completa no borra nada.
"""
function _esqueletizar_3d(mascara::Array{Bool,3}, dt::Array{Float64,3})
    nx, ny, nz = size(mascara)
    P = zeros(Bool, nx + 2, ny + 2, nz + 2)
    DT = zeros(Float64, nx + 2, ny + 2, nz + 2)
    P[2:nx+1, 2:ny+1, 2:nz+1] .= mascara
    DT[2:nx+1, 2:ny+1, 2:nz+1] .= dt

    while true
        candidatos = Tuple{Float64,Int,Int,Int}[]
        for k in 2:nz+1, j in 2:ny+1, i in 2:nx+1
            if P[i, j, k] && !(P[i-1, j, k] && P[i+1, j, k] && P[i, j-1, k] && P[i, j+1, k] && P[i, j, k-1] && P[i, j, k+1])
                push!(candidatos, (DT[i, j, k], i, j, k))
            end
        end
        sort!(candidatos)
        borrados = 0
        for (_, i, j, k) in candidatos
            fg = _vecindad_bits(P, i, j, k)
            count_ones(fg) <= 1 && continue      # punta (o vóxel aislado): se conserva
            if _es_simple(fg)
                P[i, j, k] = false
                borrados += 1
            end
        end
        borrados == 0 && break
    end
    return P[2:nx+1, 2:ny+1, 2:nz+1]
end

# --- grafo desde el esqueleto ----------------------------------------------------

struct _ArcoGrafo
    u::Int
    v::Int
    longitud::Float64     # mm, a lo largo de la línea central (suavizada)
    rad_long::Float64     # suma de (radio local × longitud): para promediar radios ponderando por longitud
    n_vox::Int
end

"""Media móvil sobre una polilínea 3×n (extremos fijos). Quita el "dentado" de
escalera de un camino de vóxeles, que de otro modo infla la longitud (un
tramo recto salía ~7% más largo) y, con ello, la tortuosidad."""
function _suavizar_polilinea(pts::Matrix{Float64}, w::Int)
    n = size(pts, 2)
    (w <= 0 || n < 3) && return pts
    out = copy(pts)
    for t in 2:n-1
        h = min(w, t - 1, n - t)
        for c in 1:3
            s = 0.0
            for u in t-h:t+h
                s += pts[c, u]
            end
            out[c, t] = s / (2h + 1)
        end
    end
    return out
end

"""
Construye el grafo del esqueleto. Nodos = grupos de vóxeles del esqueleto
con grado != 2 (grado = nº de vecinos 26): puntas (grado 1) y bifurcaciones
(grado >= 3); los vóxeles-nodo contiguos se agrupan en un solo nodo (centroide).
Aristas = cadenas de vóxeles de grado 2 entre dos nodos.

Devuelve `(pos_mm, pos_vox, aristas)`: posiciones de los nodos (3×n, en mm
desde el primer vóxel / en coordenadas de vóxel 1-indexadas) y las aristas.
"""
function _construir_grafo(esq::Array{Bool,3}, dt::Array{Float64,3}, voxel_dims; ventana::Int=2)
    nx, ny, nz = size(esq)
    mx, my, mz = nx + 2, ny + 2, nz + 2
    sx, sy, sz = Float64(voxel_dims[1]), Float64(voxel_dims[2]), Float64(voxel_dims[3])
    P = zeros(Bool, mx, my, mz)
    P[2:nx+1, 2:ny+1, 2:nz+1] .= esq

    vox = Int[]
    grado = zeros(Int8, mx, my, mz)
    for k in 2:nz+1, j in 2:ny+1, i in 2:nx+1
        if P[i, j, k]
            push!(vox, i + (j - 1) * mx + (k - 1) * mx * my)
            grado[i, j, k] = Int8(count_ones(_vecindad_bits(P, i, j, k)))
        end
    end
    es_nodo = zeros(Bool, mx, my, mz)
    for idx in vox
        g = grado[idx]
        if g != 2 && g != 0
            es_nodo[idx] = true
        end
    end

    # Agrupar vóxeles-nodo contiguos (26-conexos) en un único nodo.
    cluster = zeros(Int32, mx, my, mz)
    miembros = Vector{Vector{Int}}()
    pila = Int[]
    for idx0 in vox
        (es_nodo[idx0] && cluster[idx0] == 0) || continue
        cid = length(miembros) + 1
        lista = Int[]
        cluster[idx0] = cid
        push!(pila, idx0)
        while !isempty(pila)
            q = pop!(pila)
            push!(lista, q)
            qi, qj, qk = _ijk_grafo(q, mx, my)
            for dk in -1:1, dj in -1:1, di in -1:1
                (di == 0 && dj == 0 && dk == 0) && continue
                r = (qi + di) + (qj + dj - 1) * mx + (qk + dk - 1) * mx * my
                if es_nodo[r] && cluster[r] == 0
                    cluster[r] = cid
                    push!(pila, r)
                end
            end
        end
        push!(miembros, lista)
    end

    nn = length(miembros)
    pos_mm = zeros(3, nn)
    pos_vox = zeros(3, nn)
    for cid in 1:nn
        si = 0.0; sj = 0.0; sk = 0.0
        for q in miembros[cid]
            qi, qj, qk = _ijk_grafo(q, mx, my)
            si += qi; sj += qj; sk += qk
        end
        m = length(miembros[cid])
        ci = si / m - 1; cj = sj / m - 1; ck = sk / m - 1      # 1-indexado, sin el relleno
        pos_vox[1, cid] = ci; pos_vox[2, cid] = cj; pos_vox[3, cid] = ck
        pos_mm[1, cid] = (ci - 1) * sx; pos_mm[2, cid] = (cj - 1) * sy; pos_mm[3, cid] = (ck - 1) * sz
    end

    # Recorrer las cadenas de grado 2 que salen de cada nodo.
    visitado = zeros(Bool, mx, my, mz)
    aristas = _ArcoGrafo[]
    for cid in 1:nn
        for p in miembros[cid]
            pi_, pj, pk = _ijk_grafo(p, mx, my)
            for dk in -1:1, dj in -1:1, di in -1:1
                (di == 0 && dj == 0 && dk == 0) && continue
                r = (pi_ + di) + (pj + dj - 1) * mx + (pk + dk - 1) * mx * my
                (P[r] && !es_nodo[r] && !visitado[r]) || continue

                camino = Int[r]
                visitado[r] = true
                prev = p
                cur = r
                fin = 0
                while true
                    siguiente = 0
                    nsig = 0
                    ci_, cj_, ck_ = _ijk_grafo(cur, mx, my)
                    for ek in -1:1, ej in -1:1, ei in -1:1
                        (ei == 0 && ej == 0 && ek == 0) && continue
                        s = (ci_ + ei) + (cj_ + ej - 1) * mx + (ck_ + ek - 1) * mx * my
                        if P[s] && s != prev
                            nsig += 1
                            siguiente = s
                        end
                    end
                    nsig != 1 && break
                    if es_nodo[siguiente]
                        fin = cluster[siguiente]
                        break
                    end
                    visitado[siguiente] && break
                    push!(camino, siguiente)
                    visitado[siguiente] = true
                    prev = cur
                    cur = siguiente
                end
                fin == 0 && continue

                n_c = length(camino)
                npts = n_c + 2
                pts = zeros(3, npts)
                for c in 1:3
                    pts[c, 1] = pos_mm[c, cid]
                    pts[c, npts] = pos_mm[c, fin]
                end
                rad = 0.0
                for (t, c) in enumerate(camino)
                    ci2, cj2, ck2 = _ijk_grafo(c, mx, my)
                    pts[1, t+1] = (ci2 - 2) * sx
                    pts[2, t+1] = (cj2 - 2) * sy
                    pts[3, t+1] = (ck2 - 2) * sz
                    rad += dt[ci2-1, cj2-1, ck2-1]
                end
                rad /= n_c
                pts = _suavizar_polilinea(pts, ventana)
                L = 0.0
                for t in 1:npts-1
                    L += sqrt((pts[1, t+1] - pts[1, t])^2 + (pts[2, t+1] - pts[2, t])^2 + (pts[3, t+1] - pts[3, t])^2)
                end
                push!(aristas, _ArcoGrafo(cid, fin, L, rad * L, n_c))
            end
        end
    end
    return pos_mm, pos_vox, aristas
end

"""
Limpia el grafo: (1) poda las ramas terminales espurias — una arista con una
punta en un extremo y una bifurcación en el otro, más corta que
`max(min_len, factor_radio × radio de la rama más gruesa de esa bifurcación)`
(una irregularidad de la superficie de un vaso deja una "espina" de largo
parecido al radio del vaso); (2) funde los nodos que quedan con grado 2
(ya no son bifurcaciones) uniendo sus dos aristas en una. Repite hasta que
nada cambia. Devuelve `(aristas_vivas, grado_por_nodo)`.
"""
function _podar_y_fusionar(aristas::Vector{_ArcoGrafo}, nn::Int, min_len::Float64, factor_radio::Float64)
    ar = copy(aristas)
    vivas = fill(true, length(ar))
    deg = zeros(Int, nn)
    inc = [Int[] for _ in 1:nn]
    for (e, a) in enumerate(ar)
        deg[a.u] += 1
        deg[a.v] += 1
        push!(inc[a.u], e)
        a.v != a.u && push!(inc[a.v], e)
    end

    cambio = true
    while cambio
        cambio = false
        e = 1
        while e <= length(ar)
            if vivas[e]
                a = ar[e]
                if a.u != a.v
                    du = deg[a.u]; dv = deg[a.v]
                    if (du == 1 && dv >= 3) || (dv == 1 && du >= 3)
                        junc = du == 1 ? a.v : a.u
                        r_max = 0.0
                        for e2 in inc[junc]
                            if vivas[e2] && e2 != e
                                b = ar[e2]
                                if b.longitud > 0
                                    r_max = max(r_max, b.rad_long / b.longitud)
                                end
                            end
                        end
                        if a.longitud < max(min_len, factor_radio * r_max)
                            vivas[e] = false
                            deg[a.u] -= 1
                            deg[a.v] -= 1
                            cambio = true
                        end
                    end
                end
            end
            e += 1
        end

        for nodo in 1:nn
            deg[nodo] == 2 || continue
            alivas = [e2 for e2 in inc[nodo] if vivas[e2]]
            length(alivas) == 2 || continue
            e1, e2 = alivas
            a1 = ar[e1]; a2 = ar[e2]
            o1 = a1.u == nodo ? a1.v : a1.u
            o2 = a2.u == nodo ? a2.v : a2.u
            push!(ar, _ArcoGrafo(o1, o2, a1.longitud + a2.longitud, a1.rad_long + a2.rad_long, a1.n_vox + a2.n_vox))
            push!(vivas, true)
            nuevo = length(ar)
            push!(inc[o1], nuevo)
            o2 != o1 && push!(inc[o2], nuevo)
            vivas[e1] = false
            vivas[e2] = false
            deg[nodo] = 0
            cambio = true
        end
    end
    return [ar[e] for e in eachindex(ar) if vivas[e]], deg
end

"""Número finito o `nothing` (JSON no admite NaN/Inf)."""
_fin(x::Real) = isfinite(x) ? Float64(x) : nothing

"""
Resumen del grafo: dict con `"metricas"`, `"nodos"` y `"aristas"` (nodos
renumerados 1..n, solo los que tienen al menos una arista).
"""
function _resumir_grafo(aristas::Vector{_ArcoGrafo}, deg::Vector{Int}, pos_mm::Matrix{Float64}, pos_vox::Matrix{Float64})
    nn = length(deg)
    usados = [n for n in 1:nn if deg[n] > 0]
    nuevo_id = zeros(Int, nn)
    for (t, n) in enumerate(usados)
        nuevo_id[n] = t
    end

    padre = collect(1:nn)
    raiz = function (x)
        while padre[x] != x
            padre[x] = padre[padre[x]]
            x = padre[x]
        end
        return x
    end
    for a in aristas
        ra = raiz(a.u); rb = raiz(a.v)
        ra != rb && (padre[ra] = rb)
    end
    n_comp = length(unique(raiz(n) for n in usados))

    long_total = 0.0
    rad_long_total = 0.0
    tort = Float64[]
    aristas_json = Vector{Dict{String,Any}}()
    for (e, a) in enumerate(aristas)
        long_total += a.longitud
        rad_long_total += a.rad_long
        recta = sqrt((pos_mm[1, a.u] - pos_mm[1, a.v])^2 + (pos_mm[2, a.u] - pos_mm[2, a.v])^2 + (pos_mm[3, a.u] - pos_mm[3, a.v])^2)
        t = recta > 1e-9 ? a.longitud / recta : nothing
        t !== nothing && push!(tort, t)
        push!(aristas_json, Dict{String,Any}(
            "id" => e, "u" => nuevo_id[a.u], "v" => nuevo_id[a.v],
            "longitud_mm" => _fin(a.longitud),
            "radio_medio_mm" => a.longitud > 0 ? _fin(a.rad_long / a.longitud) : nothing,
            "tortuosidad" => t === nothing ? nothing : _fin(t),
            "n_voxeles" => a.n_vox,
        ))
    end

    nodos_json = Vector{Dict{String,Any}}()
    n_bif = 0
    n_punta = 0
    for n in usados
        tipo = deg[n] == 1 ? "punta" : (deg[n] >= 3 ? "bifurcacion" : "otro")
        tipo == "bifurcacion" && (n_bif += 1)
        tipo == "punta" && (n_punta += 1)
        push!(nodos_json, Dict{String,Any}(
            "id" => nuevo_id[n], "tipo" => tipo, "grado" => deg[n],
            "posicion_voxel" => [_fin(pos_vox[1, n]), _fin(pos_vox[2, n]), _fin(pos_vox[3, n])],
            "posicion_mm" => [_fin(pos_mm[1, n]), _fin(pos_mm[2, n]), _fin(pos_mm[3, n])],
        ))
    end

    metricas = Dict{String,Any}(
        "num_nodos" => length(usados),
        "num_bifurcaciones" => n_bif,
        "num_puntas" => n_punta,
        "num_aristas" => length(aristas),
        "longitud_vascular_total_mm" => _fin(long_total),
        "radio_promedio_mm" => long_total > 0 ? _fin(rad_long_total / long_total) : nothing,
        "tortuosidad_promedio" => isempty(tort) ? nothing : _fin(sum(tort) / length(tort)),
        "num_componentes" => n_comp,
        "ciclos_independientes" => length(aristas) - length(usados) + n_comp,
    )
    return Dict{String,Any}("metricas" => metricas, "nodos" => nodos_json, "aristas" => aristas_json)
end

# --- imagen de validación: proyección del esqueleto --------------------------------

function _rgb_png_base64(R::Matrix{Float64}, G::Matrix{Float64}, B::Matrix{Float64})
    try
        img = RGB.(R, G, B)
        buffer = IOBuffer()
        FileIO.save(FileIO.Stream{FileIO.DataFormat{:PNG}}(buffer), img)
        return "data:image/png;base64," * base64encode(take!(buffer))
    catch e
        println("Advertencia: error generando el PNG de la proyección: $e")
        return "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    end
end

"""
Proyección axial (a lo largo de z) de la máscara (gris), el esqueleto (rojo),
las bifurcaciones (amarillo) y las puntas (cian) — para ver de un vistazo si
el árbol detectado tiene forma de árbol vascular. Misma orientación que el
corte axial (`extract_slice`, `rotr90`).
"""
function _proyeccion_esqueleto_png(mascara::Array{Bool,3}, esq::Array{Bool,3}, nodos_json::Vector{Dict{String,Any}})
    nx, ny, nz = size(mascara)
    R = zeros(Float64, nx, ny); G = zeros(Float64, nx, ny); B = zeros(Float64, nx, ny)
    proy_esq = zeros(Bool, nx, ny)
    for k in 1:nz, j in 1:ny, i in 1:nx
        if mascara[i, j, k]
            R[i, j] = 0.30; G[i, j] = 0.30; B[i, j] = 0.30
        end
        esq[i, j, k] && (proy_esq[i, j] = true)
    end
    for j in 1:ny, i in 1:nx
        proy_esq[i, j] || continue
        for dj in -1:1, di in -1:1          # engrosado de 1 píxel para que se vea
            a = i + di; b = j + dj
            (a < 1 || a > nx || b < 1 || b > ny) && continue
            R[a, b] = 1.0; G[a, b] = 0.15; B[a, b] = 0.10
        end
    end
    for nodo in nodos_json
        tipo = nodo["tipo"]
        (tipo == "bifurcacion" || tipo == "punta") || continue
        pv = nodo["posicion_voxel"]
        (pv[1] === nothing || pv[2] === nothing) && continue
        ci = round(Int, pv[1]); cj = round(Int, pv[2])
        for dj in -2:2, di in -2:2
            a = ci + di; b = cj + dj
            (a < 1 || a > nx || b < 1 || b > ny) && continue
            if tipo == "bifurcacion"
                R[a, b] = 1.0; G[a, b] = 0.9; B[a, b] = 0.1
            else
                R[a, b] = 0.1; G[a, b] = 0.8; B[a, b] = 1.0
            end
        end
    end
    return _rgb_png_base64(Matrix(rotr90(R)), Matrix(rotr90(G)), Matrix(rotr90(B)))
end

# ==============================================================================
# DE LA MÁSCARA AL GRAFO (sin lectura de archivos; lo usa también la autoprueba)
# ==============================================================================

"""
Máscara binaria -> grafo. Devuelve `(grafo, esqueleto)` donde `grafo` es el
dict de `_resumir_grafo` (`"metricas"`, `"nodos"`, `"aristas"`).
"""
function _grafo_de_mascara(mascara::Array{Bool,3}, voxel_dims;
                            min_len::Float64=3.0, factor_radio::Float64=1.5, ventana::Int=2)
    dt = _transformada_distancia(mascara, voxel_dims)
    esq = _esqueletizar_3d(mascara, dt)
    pos_mm, pos_vox, aristas = _construir_grafo(esq, dt, voxel_dims; ventana=ventana)
    ar, deg = _podar_y_fusionar(aristas, size(pos_mm, 2), min_len, factor_radio)
    return _resumir_grafo(ar, deg, pos_mm, pos_vox), esq
end

# ==============================================================================
# CORTES DE VALIDACIÓN (visor interactivo del frontend)
# ==============================================================================
#
# Cada análisis deja en `GrafosCache` el volumen, la máscara, el esqueleto y
# los nodos (ver `registrar_resultado` en `analizar_grafos`); el endpoint
# `POST /api/grafos/corte` llama a `renderizar_corte_grafo` para dibujar el
# corte pedido sin recalcular nada.

"""Rango de intensidades para mostrar el volumen: percentiles 0,5 y 99,5 sobre
una muestra (contraste parejo entre cortes, sin que un par de vóxeles
extremos aplaste el resto)."""
function _rango_visualizacion(volumen::AbstractArray)
    n = length(volumen)
    paso = max(1, n ÷ 200_000)
    muestra = sort!(Float64[Float64(volumen[i]) for i in 1:paso:n])
    m = length(muestra)
    lo = muestra[clamp(round(Int, 0.005 * m) + 1, 1, m)]
    hi = muestra[clamp(round(Int, 0.995 * m), 1, m)]
    hi <= lo && (hi = lo + 1.0)
    return lo, hi
end

"""
    renderizar_corte_grafo(datos, orientacion, indice; mostrar_mascara, mostrar_esqueleto,
                           mostrar_nodos, grosor) -> (png_base64, total_cortes, indice_usado)

Corte `indice` (1-indexado) de `datos.volumen` en la `orientacion` dada
("axial", "coronal" o "sagittal", la misma convención y orientación que
`extract_slice`) con capas superpuestas: máscara vascular (azul translúcido),
esqueleto (rojo) y nodos (bifurcaciones amarillo, puntas cian).

Un corte de un esqueleto de 1 vóxel de grosor solo muestra puntos sueltos, así
que `grosor` proyecta sobre el corte el esqueleto y los nodos de los `grosor`
cortes vecinos a cada lado (0 = solo este corte).
"""
function renderizar_corte_grafo(datos, orientacion::AbstractString, indice::Integer;
                                 mostrar_mascara::Bool=true, mostrar_esqueleto::Bool=true,
                                 mostrar_nodos::Bool=true, grosor::Integer=0)
    orient = String(orientacion)
    vol = datos.volumen
    nx, ny, nz = size(vol)
    eje = orient == "sagittal" ? 1 : (orient == "coronal" ? 2 : 3)
    total = size(vol, eje)
    idx = clamp(Int(indice), 1, total)
    grosor = max(0, Int(grosor))

    base = extract_slice(vol, orient, idx)
    filas, cols = size(base)
    R = zeros(Float64, filas, cols); G = zeros(Float64, filas, cols); B = zeros(Float64, filas, cols)
    lo, hi = datos.vmin, datos.vmax
    for j in 1:cols, i in 1:filas
        v = clamp((Float64(base[i, j]) - lo) / (hi - lo), 0.0, 1.0)
        R[i, j] = v; G[i, j] = v; B[i, j] = v
    end

    if mostrar_mascara
        m = extract_slice(datos.mascara, orient, idx)
        alfa = 0.40
        for j in 1:cols, i in 1:filas
            if m[i, j]
                R[i, j] = (1 - alfa) * R[i, j] + alfa * 0.15
                G[i, j] = (1 - alfa) * G[i, j] + alfa * 0.55
                B[i, j] = (1 - alfa) * B[i, j] + alfa * 1.00
            end
        end
    end

    if mostrar_esqueleto
        for s in max(1, idx - grosor):min(total, idx + grosor)
            e = extract_slice(datos.esqueleto, orient, s)
            for j in 1:cols, i in 1:filas
                if e[i, j]
                    R[i, j] = 1.0; G[i, j] = 0.15; B[i, j] = 0.10
                end
            end
        end
    end

    if mostrar_nodos
        for nodo in datos.nodos
            tipo = nodo["tipo"]
            (tipo == "bifurcacion" || tipo == "punta") || continue
            pv = nodo["posicion_voxel"]
            (pv[1] === nothing || pv[2] === nothing || pv[3] === nothing) && continue
            px, py, pz = pv[1], pv[2], pv[3]
            coord_eje = eje == 1 ? px : (eje == 2 ? py : pz)
            abs(coord_eje - idx) <= grosor + 0.5 || continue
            # (fila, columna) del vóxel en la imagen: depende de las rotaciones de `extract_slice`
            fila, col = orient == "axial" ? (py, nx - px + 1) :
                        orient == "coronal" ? (pz, nx - px + 1) :
                                              (nz - pz + 1, ny - py + 1)
            fi = round(Int, fila); ci = round(Int, col)
            for dj in -2:2, di in -2:2
                a = fi + di; b = ci + dj
                (a < 1 || a > filas || b < 1 || b > cols) && continue
                if tipo == "bifurcacion"
                    R[a, b] = 1.0; G[a, b] = 0.9; B[a, b] = 0.1
                else
                    R[a, b] = 0.1; G[a, b] = 0.8; B[a, b] = 1.0
                end
            end
        end
    end

    return _rgb_png_base64(R, G, B), total, idx
end

# ==============================================================================
# PIPELINE POR ARCHIVO
# ==============================================================================

function _analizar_grafo_vascular(archivo::AbstractString, opciones, dir_salida, registrar_resultado)
    nombre_archivo = basename(archivo)
    try
        if !isfile(archivo)
            return Dict("archivo" => nombre_archivo, "success" => false, "error" => "Archivo no encontrado")
        end

        # Preprocesamiento (PreprocesamientoGrafos.jl): archivo -> máscara vascular limpia.
        mascara, volumen, voxel_dims, pre = preprocesar_volumen_grafos(archivo, opciones)

        n_vox = count(mascara)
        if n_vox == 0
            return Dict("archivo" => nombre_archivo, "success" => false,
                        "error" => "La máscara vascular quedó vacía tras el preprocesamiento (revisar umbral, escalas o min_voxeles_componente)")
        end

        # Análisis: máscara -> esqueleto -> grafo.
        min_len = Float64(get(opciones, "longitud_min_rama_mm", 3.0))
        factor_radio = Float64(get(opciones, "factor_radio_poda", 1.5))
        ventana = Int(get(opciones, "ventana_suavizado", 2))
        grafo, esq = _grafo_de_mascara(mascara, voxel_dims; min_len=min_len, factor_radio=factor_radio, ventana=ventana)

        parametros = Dict{String,Any}(
            "longitud_min_rama_mm" => min_len,
            "factor_radio_poda" => factor_radio,
            "ventana_suavizado" => ventana,
        )

        # El grafo completo (nodos y aristas) se guarda aparte: es el insumo de la Fase 3 y de
        # cualquier análisis posterior; la respuesta HTTP lleva solo las métricas.
        ruta_json = nothing
        if !isnothing(dir_salida)
            try
                mkpath(dir_salida)
                base = replace(nombre_archivo, r"\.(nii\.gz|nii|dcm|dicom|ima)$"i => "")
                base = replace(base, r"[^A-Za-z0-9_.-]" => "_")
                marca = Dates.format(now(), "yyyymmdd_HHMMSS")
                ruta_json = joinpath(dir_salida, "grafo_$(base)_$(marca).json")
                open(ruta_json, "w") do io
                    JSON3.write(io, Dict{String,Any}(
                        "archivo" => nombre_archivo,
                        "voxel_dims_mm" => pre["voxel_dims_mm"],
                        "region" => pre["region"],
                        "preprocesamiento" => pre["deteccion_vascular"],
                        "parametros_grafo" => parametros,
                        "grafo" => grafo,
                    ))
                end
            catch e
                println("⚠️  No se pudo guardar el grafo en JSON: $e")
                ruta_json = nothing
            end
        end

        # Visor de cortes: se guardan los datos para servir cortes bajo demanda.
        resultado_id = nothing
        if !isnothing(registrar_resultado)
            try
                lo_vis, hi_vis = _rango_visualizacion(volumen)
                resultado_id = registrar_resultado((
                    volumen=Float32.(volumen), mascara=mascara, esqueleto=esq, nodos=grafo["nodos"],
                    voxel_dims=voxel_dims, vmin=lo_vis, vmax=hi_vis,
                ))
            catch e
                println("⚠️  No se pudieron guardar los datos del visor de cortes: $e")
                resultado_id = nothing
            end
        end

        return Dict(
            "archivo" => nombre_archivo,
            "success" => true,
            "resultado_id" => resultado_id,
            "dimensiones" => collect(size(mascara)),
            "voxel_dims_mm" => pre["voxel_dims_mm"],
            "region" => pre["region"],
            "deteccion_vascular" => pre["deteccion_vascular"],
            "esqueleto" => Dict("voxeles" => count(esq)),
            "grafo" => Dict(
                "metricas" => grafo["metricas"],
                "parametros" => parametros,
                "ruta_json" => ruta_json,
            ),
            "visualizacion" => Dict(
                "proyeccion_esqueleto_png" => _proyeccion_esqueleto_png(mascara, esq, grafo["nodos"]),
            ),
            "fase_pipeline" => "Fase 2",
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
    analizar_grafos(archivos, tipo_grafo, opciones; on_progreso, dir_salida) -> Dict

`opciones` (sin tipar `Dict`: llega tal cual del handler, puede ser un
`JSON3.Object`, igual que `grupos` en `analizar_estadistico`): ver la lista de
opciones en las cabeceras de este archivo y de PreprocesamientoGrafos.jl.

`on_progreso`, si se da, es `(completados::Int, total::Int) -> nothing` — mismo
contrato que en `analizar_radiomico`. `dir_salida`, si se da, es la carpeta
donde se guarda el JSON del grafo de cada archivo. `registrar_resultado`, si
se da, recibe los datos de cada resultado (volumen, máscara, esqueleto, nodos)
y devuelve un `resultado_id` — el handler pasa `GrafosCache.registrar!` para
que el visor de cortes pueda pedirlos después sin recalcular.
"""
function analizar_grafos(archivos::Vector{String}, tipo_grafo::AbstractString, opciones;
                          on_progreso::Union{Function,Nothing}=nothing,
                          dir_salida::Union{AbstractString,Nothing}=nothing,
                          registrar_resultado::Union{Function,Nothing}=nothing)
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
        push!(resultados, _analizar_grafo_vascular(archivo, opciones, dir_salida, registrar_resultado))
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
Las imágenes NO se escriben acá (viven en la respuesta JSON para el frontend);
el grafo completo está en el JSON cuya ruta aparece en la última columna.
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
                       "Nodos", "Bifurcaciones", "Puntas", "Aristas", "Longitud total (mm)",
                       "Radio promedio (mm)", "Tortuosidad promedio", "Componentes", "Ciclos independientes",
                       "Umbral vesselness", "Región", "Archivo del grafo (JSON)", "Nota / error"]
        for (col, encabezado) in enumerate(encabezados)
            sheet[XLSX.CellRef(1, col)] = encabezado
        end

        for (fila_idx, r) in enumerate(resultados)
            fila = fila_idx + 1
            d = get(r, "deteccion_vascular", Dict())
            g = get(get(r, "grafo", Dict()), "metricas", Dict())
            valores = Any[
                get(r, "archivo", ""),
                get(r, "success", false) ? "Completado" : "Error",
                get(d, "voxeles_vasculares", ""),
                get(d, "fraccion_volumen", ""),
                get(g, "num_nodos", ""),
                get(g, "num_bifurcaciones", ""),
                get(g, "num_puntas", ""),
                get(g, "num_aristas", ""),
                get(g, "longitud_vascular_total_mm", ""),
                get(g, "radio_promedio_mm", ""),
                get(g, "tortuosidad_promedio", ""),
                get(g, "num_componentes", ""),
                get(g, "ciclos_independientes", ""),
                get(d, "umbral_vesselness", ""),
                get(get(r, "region", Dict()), "origen", ""),
                something(get(get(r, "grafo", Dict()), "ruta_json", nothing), ""),
                get(r, "fase_pipeline", get(r, "error", "")),
            ]
            for (col, valor) in enumerate(valores)
                sheet[XLSX.CellRef(fila, col)] = valor === nothing ? "" : valor
            end
        end
    end

    println("📊 Excel guardado: $ruta_completa")
    return ruta_completa
end

# ==============================================================================
# AUTOPRUEBA — fantomas con respuesta conocida, sin necesitar archivos reales.
#   julia --project=. -e 'include("AnalisisGrafos.jl"); autoprueba_grafos()'
# Los resultados esperados salen del prototipo de referencia en Python
# (docs/referencia/prototipo_fase2.py), que corrió los mismos fantomas.
# ==============================================================================

"""Máscara 3D de la unión de cápsulas `(p0, p1, radio)` (coordenadas 1-indexadas)."""
function _fantoma_capsulas(dims::NTuple{3,Int}, segs)
    m = zeros(Bool, dims[1], dims[2], dims[3])
    for k in 1:dims[3], j in 1:dims[2], i in 1:dims[1]
        for (p0, p1, r) in segs
            dx = p1[1] - p0[1]; dy = p1[2] - p0[2]; dz = p1[3] - p0[3]
            t = clamp(((i - p0[1]) * dx + (j - p0[2]) * dy + (k - p0[3]) * dz) / (dx * dx + dy * dy + dz * dz), 0.0, 1.0)
            if sqrt((i - (p0[1] + t * dx))^2 + (j - (p0[2] + t * dy))^2 + (k - (p0[3] + t * dz))^2) <= r
                m[i, j, k] = true
                break
            end
        end
    end
    return m
end

function autoprueba_grafos()
    ok = true
    chequear = function (nombre, cond)
        println(cond ? "  ✅ " : "  ❌ ", nombre)
        return cond
    end
    println("Autoprueba del análisis por grafos (Fase 2)")
    dims1 = (1.0, 1.0, 1.0)

    # 1) Árbol en Y: 1 bifurcación, 3 puntas, 3 aristas, ramas rectas.
    y = _fantoma_capsulas((50, 50, 60), [((26, 26, 6), (26, 26, 29), 3.2),
                                          ((26, 26, 29), (13, 26, 53), 2.6),
                                          ((26, 26, 29), (39, 26, 53), 2.6)])
    g, esq = _grafo_de_mascara(y, dims1)
    m = g["metricas"]
    ok &= chequear("Y: 4 nodos, 1 bifurcación, 3 puntas, 3 aristas",
                   (m["num_nodos"], m["num_bifurcaciones"], m["num_puntas"], m["num_aristas"]) == (4, 1, 3, 3))
    ok &= chequear("Y: 1 componente, 0 ciclos", m["num_componentes"] == 1 && m["ciclos_independientes"] == 0)
    ok &= chequear("Y: tortuosidad promedio ≈ 1 ($(m["tortuosidad_promedio"]))",
                   m["tortuosidad_promedio"] !== nothing && m["tortuosidad_promedio"] < 1.03)
    ok &= chequear("Y: el esqueleto es mucho más chico que la máscara ($(count(esq)) vs $(count(y)) vóxeles)", count(esq) < count(y) ÷ 10)

    # 2) Anillo con cola: un lazo (arista que vuelve al mismo nodo) + la cola.
    anillo = zeros(Bool, 60, 60, 30)
    for k in 1:30, j in 1:60, i in 1:60
        rho = sqrt((i - 31.0)^2 + (j - 31.0)^2)
        ((rho - 14)^2 + (k - 16.0)^2 <= 3.0^2) && (anillo[i, j, k] = true)
    end
    cola = _fantoma_capsulas((60, 60, 30), [((45, 31, 16), (58, 31, 16), 2.5)])
    anillo .|= cola
    g, _ = _grafo_de_mascara(anillo, dims1)
    m = g["metricas"]
    ok &= chequear("anillo+cola: 2 nodos, 1 bifurcación, 1 punta, 2 aristas",
                   (m["num_nodos"], m["num_bifurcaciones"], m["num_puntas"], m["num_aristas"]) == (2, 1, 1, 2))
    ok &= chequear("anillo+cola: 1 componente, 1 ciclo", m["num_componentes"] == 1 && m["ciclos_independientes"] == 1)

    # 3) Y con 10 "espinas" en la superficie: la poda las elimina y queda el mismo Y.
    espinas = [(29.2, 26.0, 11.0), (22.8, 26.0, 15.0), (26.0, 29.2, 19.0), (26.0, 22.8, 23.0), (29.2, 26.0, 26.0),
               (23.0, 26.0, 40.0), (17.5, 26.0, 46.0), (31.0, 26.0, 40.0), (36.5, 26.0, 46.0), (26.0, 22.8, 9.0)]
    yr = copy(y)
    for k in 1:60, j in 1:50, i in 1:50
        for (bx, by, bz) in espinas
            if sqrt((i - bx)^2 + (j - by)^2 + (k - bz)^2) <= 1.8
                yr[i, j, k] = true
                break
            end
        end
    end
    g, _ = _grafo_de_mascara(yr, dims1)
    m = g["metricas"]
    ok &= chequear("Y con espinas: tras la poda, otra vez 4 nodos, 1 bifurcación, 3 puntas, 3 aristas",
                   (m["num_nodos"], m["num_bifurcaciones"], m["num_puntas"], m["num_aristas"]) == (4, 1, 3, 3))

    # 4) Y con vóxel anisotrópico (1,1,2): las longitudes en mm crecen con el espaciado en z.
    ga, _ = _grafo_de_mascara(y, (1.0, 1.0, 2.0))
    ok &= chequear("Y anisotrópico: longitud total mayor que la isotrópica",
                   ga["metricas"]["longitud_vascular_total_mm"] > 1.5 * m["longitud_vascular_total_mm"])

    # 5) EDT exacta vs fuerza bruta, con espaciado anisotrópico.
    estado = UInt64(2024)
    azar01 = function ()
        estado = estado * 6364136223846793005 + 1442695040888963407
        return Float64(estado >> 11) / Float64(UInt64(1) << 53)
    end
    forma = (6, 5, 4)
    dd = (0.8, 0.8, 2.5)
    mk = zeros(Bool, forma...)
    for idx in eachindex(mk)
        mk[idx] = azar01() < 0.65
    end
    mk[1, 1, 1] = false     # al menos un vóxel de fondo
    dt = _transformada_distancia(mk, dd)
    peor = 0.0
    for k in 1:forma[3], j in 1:forma[2], i in 1:forma[1]
        mk[i, j, k] || continue
        mejor = Inf
        for kb in 1:forma[3], jb in 1:forma[2], ib in 1:forma[1]
            mk[ib, jb, kb] && continue
            mejor = min(mejor, sqrt(((i - ib) * dd[1])^2 + ((j - jb) * dd[2])^2 + ((k - kb) * dd[3])^2))
        end
        peor = max(peor, abs(dt[i, j, k] - mejor))
    end
    ok &= chequear("EDT = fuerza bruta con espaciado anisotrópico (peor diferencia $(peor))", peor < 1e-9)

    println(ok ? "✅ Autoprueba del análisis por grafos: todo en orden" : "❌ Autoprueba del análisis por grafos: HAY FALLOS")
    return ok
end
