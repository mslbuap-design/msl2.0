# ==============================================================================
# MetricasGrafos.jl — Métricas avanzadas de un grafo vascular (Fase 3A)
# ==============================================================================
#
# Entrada: el grafo que arma AnalisisGrafos.jl (`_resumir_grafo`):
#   {"nodos": [{"id","tipo","grado",...}], "aristas": [{"id","u","v","longitud_mm",
#    "radio_medio_mm","tortuosidad","n_voxeles","dir_u","dir_v"}]}
# con los nodos numerados 1..n. `dir_u`/`dir_v` = vector unitario con el que la
# arista SALE de su extremo u/v. Este archivo no toca imágenes: solo calcula sobre
# el grafo (por eso se puede probar con grafos armados a mano, ver
# `autoprueba_metricas`).
#
# Salida de `calcular_metricas_avanzadas(grafo)`:
#   "estructura"      métricas agrupadas (estadísticos completos, valores por orden de Strahler, ...)
#   "caracteristicas" las mismas, APLANADAS: un número por característica (o `nothing`) — es la fila
#                     del sujeto en la tabla que luego se compara entre grupos (Fase 3B)
#   "histogramas"     distribución por arista del radio, la longitud y la tortuosidad (20 bins)
#
# Árbol y raíz. La jerarquía (generación, orden de Strahler, caminos desde la raíz,
# ángulos entre ramas) necesita un árbol con una raíz. Por cada componente conexa:
#   1. Raíz = un extremo de la arista de MAYOR RADIO (se ignoran las aristas más cortas que
#      2 radios, porque su radio medido lo domina el ensanchamiento de la unión). De los dos
#      extremos se toma el que tiene MENOS arista "detrás" (la entrada de un tronco suele ser
#      un tramo corto, típicamente una punta); si empatan, el de menor índice.
#   2. Árbol = recorrido en anchura (BFS) desde la raíz. Si la componente tiene ciclos, las
#      aristas que cierran un ciclo quedan fuera del árbol (se cuentan en
#      `aristas_fuera_del_arbol`) y no entran en las métricas de jerarquía; las métricas
#      por arista (radios, longitudes, tortuosidad) sí usan TODAS las aristas.
#
# Estos algoritmos se escribieron y verificaron primero en
# docs/referencia/prototipo_metricas.py (árboles con respuesta analítica); este código es
# el port de esa lógica. Correr la autoprueba suelta:
#   julia --project=. -e 'include("MetricasGrafos.jl"); autoprueba_metricas()'
# ==============================================================================

# ------------------------------------------------------------------------------
# Utilidades estadísticas
# ------------------------------------------------------------------------------

"""Número finito, o `nothing` (JSON no admite NaN/Inf). Deja pasar lo que no es número."""
_numero_json(x) = (x isa Real && !isfinite(x)) ? nothing : x

"""n, media, desviación estándar muestral (n-1), mediana, p10, p25, p75, p90, mín y máx de los valores
finitos. Los percentiles usan interpolación lineal (igual que `numpy.percentile` por defecto)."""
function _estadisticos(valores)
    v = sort!(Float64[Float64(x) for x in valores if x !== nothing && isfinite(x)])
    n = length(v)
    if n == 0
        return Dict{String,Any}("n" => 0, "media" => nothing, "sd" => nothing, "mediana" => nothing, "p10" => nothing,
                                "p25" => nothing, "p75" => nothing, "p90" => nothing, "min" => nothing, "max" => nothing)
    end
    media = sum(v) / n
    sd = n > 1 ? sqrt(sum((x - media)^2 for x in v) / (n - 1)) : nothing
    q = function (p)
        pos = p * (n - 1)
        lo = floor(Int, pos)
        hi = min(lo + 1, n - 1)
        return v[lo+1] + (pos - lo) * (v[hi+1] - v[lo+1])
    end
    return Dict{String,Any}("n" => n, "media" => media, "sd" => sd, "mediana" => q(0.5), "p10" => q(0.1),
                            "p25" => q(0.25), "p75" => q(0.75), "p90" => q(0.9), "min" => v[1], "max" => v[end])
end

"""Media de `valores` ponderada por `pesos` (ignora pares no finitos o con peso <= 0); `nothing` si no hay datos."""
function _media_ponderada(valores, pesos)
    num = 0.0
    den = 0.0
    for (x, w) in zip(valores, pesos)
        if x !== nothing && w !== nothing && isfinite(x) && isfinite(w) && w > 0
            num += x * w
            den += w
        end
    end
    return den > 0 ? num / den : nothing
end

"""Histograma de `nbins` clases de igual ancho entre el mínimo y el máximo; `nothing` si no hay datos."""
function _histograma(valores; nbins::Int=20)
    v = Float64[Float64(x) for x in valores if x !== nothing && isfinite(x)]
    isempty(v) && return nothing
    lo, hi = extrema(v)
    if hi <= lo
        return Dict{String,Any}("bordes" => [lo, hi], "conteos" => [length(v)])
    end
    ancho = (hi - lo) / nbins
    conteos = zeros(Int, nbins)
    for x in v
        conteos[min(nbins, floor(Int, (x - lo) / ancho) + 1)] += 1
    end
    return Dict{String,Any}("bordes" => [lo + i * ancho for i in 0:nbins], "conteos" => conteos)
end

"""Pendiente de la recta de mínimos cuadrados de ln(y) contra k (ignora y <= 0); `nothing` si hay < 2 puntos."""
function _pendiente_log(ks, ys)
    pk = Float64[]
    py = Float64[]
    for (k, y) in zip(ks, ys)
        if y !== nothing && isfinite(y) && y > 0
            push!(pk, Float64(k))
            push!(py, log(Float64(y)))
        end
    end
    length(pk) < 2 && return nothing
    kb = sum(pk) / length(pk)
    yb = sum(py) / length(py)
    den = sum((k - kb)^2 for k in pk)
    den > 0 || return nothing
    return sum((pk[i] - kb) * (py[i] - yb) for i in eachindex(pk)) / den
end

"""Ángulo en grados entre dos vectores unitarios; `nothing` si alguno tiene NaN."""
function _angulo_grados(a::NTuple{3,Float64}, b::NTuple{3,Float64})
    (any(isnan, a) || any(isnan, b)) && return nothing
    d = clamp(a[1] * b[1] + a[2] * b[2] + a[3] * b[3], -1.0, 1.0)
    return rad2deg(acos(d))
end

"""x tal que rp^x = r1^x + r2^x (x = 3 es la ley de Murray); `nothing` si no existe (alguna hija >= padre)."""
function _exponente_union(rp, r1, r2)
    (rp > 0 && r1 > 0 && r2 > 0 && r1 < rp && r2 < rp) || return nothing
    a = r1 / rp
    b = r2 / rp
    lo = 0.0
    hi = 1.0
    while a^hi + b^hi > 1.0
        hi *= 2.0
        hi > 64 && return nothing
    end
    for _ in 1:100
        mid = (lo + hi) / 2
        if a^mid + b^mid > 1.0
            lo = mid
        else
            hi = mid
        end
    end
    return (lo + hi) / 2
end

# ------------------------------------------------------------------------------
# Grafo en arreglos
# ------------------------------------------------------------------------------

struct _GrafoPlano
    n::Int
    m::Int
    grado::Vector{Int}
    eu::Vector{Int}
    ev::Vector{Int}
    L::Vector{Float64}
    R::Vector{Float64}
    T::Vector{Float64}
    du::Vector{NTuple{3,Float64}}
    dv::Vector{NTuple{3,Float64}}
    inc::Vector{Vector{Int}}      # aristas incidentes por nodo (un lazo figura una sola vez)
end

_num(x) = x === nothing ? NaN : Float64(x)

function _vec3(x)
    (x === nothing || length(x) < 3) && return (NaN, NaN, NaN)
    return (_num(x[1]), _num(x[2]), _num(x[3]))
end

function _plano(grafo)
    nodos = grafo["nodos"]
    aristas = grafo["aristas"]
    n = length(nodos)
    m = length(aristas)
    inc = [Int[] for _ in 1:n]
    eu = Int[Int(a["u"]) for a in aristas]
    ev = Int[Int(a["v"]) for a in aristas]
    for e in 1:m
        push!(inc[eu[e]], e)
        ev[e] != eu[e] && push!(inc[ev[e]], e)
    end
    return _GrafoPlano(
        n, m,
        Int[Int(nd["grado"]) for nd in nodos],
        eu, ev,
        Float64[_num(a["longitud_mm"]) for a in aristas],
        Float64[_num(a["radio_medio_mm"]) for a in aristas],
        Float64[_num(a["tortuosidad"]) for a in aristas],
        NTuple{3,Float64}[_vec3(get(a, "dir_u", nothing)) for a in aristas],
        NTuple{3,Float64}[_vec3(get(a, "dir_v", nothing)) for a in aristas],
        inc,
    )
end

_otro(g::_GrafoPlano, e::Int, u::Int) = g.eu[e] == u ? g.ev[e] : g.eu[e]
"""Dirección con la que la arista `e` sale del nodo `v`."""
_dir_en(g::_GrafoPlano, e::Int, v::Int) = g.eu[e] == v ? g.du[e] : g.dv[e]
_l0(g::_GrafoPlano, e::Int) = isfinite(g.L[e]) ? g.L[e] : 0.0

"""Componentes conexas (listas de nodos ordenadas); los nodos sin aristas se ignoran."""
function _componentes(g::_GrafoPlano)
    comp = zeros(Int, g.n)
    lista = Vector{Vector{Int}}()
    for s in 1:g.n
        (comp[s] != 0 || isempty(g.inc[s])) && continue
        cid = length(lista) + 1
        comp[s] = cid
        pila = Int[s]
        nodos = Int[]
        while !isempty(pila)
            u = pop!(pila)
            push!(nodos, u)
            for e in g.inc[u]
                v = _otro(g, e, u)
                if comp[v] == 0
                    comp[v] = cid
                    push!(pila, v)
                end
            end
        end
        push!(lista, sort!(nodos))
    end
    return lista
end

"""Nodos alcanzables desde `inicio` sin cruzar la arista `excluida`, y la longitud de las aristas recorridas."""
function _lado(g::_GrafoPlano, inicio::Int, excluida::Int)
    vis = Set{Int}([inicio])
    pila = Int[inicio]
    ar = Set{Int}()
    while !isempty(pila)
        u = pop!(pila)
        for e in g.inc[u]
            e == excluida && continue
            push!(ar, e)
            v = _otro(g, e, u)
            if !(v in vis)
                push!(vis, v)
                push!(pila, v)
            end
        end
    end
    return vis, sum((_l0(g, e) for e in ar); init=0.0)
end

"""Raíz del árbol de una componente (ver la cabecera del archivo); 0 si no tiene aristas que no sean lazos."""
function _elegir_raiz(g::_GrafoPlano, nodos::Vector{Int})
    aristas = sort!(unique(Int[e for u in nodos for e in g.inc[u]]))
    cand = Int[e for e in aristas if g.eu[e] != g.ev[e]]
    isempty(cand) && return 0
    eleg = Int[e for e in cand if g.R[e] > 0 && g.L[e] >= 2 * g.R[e]]
    isempty(eleg) && (eleg = cand)
    # mayor radio; desempate: mayor longitud; luego menor índice
    clave(e) = (isfinite(g.R[e]) ? g.R[e] : -Inf, isfinite(g.L[e]) ? g.L[e] : -Inf, -e)
    estrella = eleg[1]
    for e in eleg
        if clave(e) > clave(estrella)
            estrella = e
        end
    end
    u = g.eu[estrella]
    v = g.ev[estrella]
    vis_u, long_u = _lado(g, u, estrella)
    (v in vis_u) && return min(u, v)           # la arista está en un ciclo: no separa la componente
    _, long_v = _lado(g, v, estrella)
    long_u < long_v && return u
    long_v < long_u && return v
    return min(u, v)
end

"""BFS desde la raíz: `(orden, padre, arista_padre, en_arbol)`. `padre`/`arista_padre` valen 0 en la raíz."""
function _arbol_generador(g::_GrafoPlano, raiz::Int)
    padre = zeros(Int, g.n)
    epadre = zeros(Int, g.n)
    visto = fill(false, g.n)
    en_arbol = fill(false, g.m)
    visto[raiz] = true
    orden = Int[raiz]
    i = 1
    while i <= length(orden)
        u = orden[i]
        i += 1
        for e in g.inc[u]
            g.eu[e] == g.ev[e] && continue
            v = _otro(g, e, u)
            if !visto[v]
                visto[v] = true
                padre[v] = u
                epadre[v] = e
                en_arbol[e] = true
                push!(orden, v)
            end
        end
    end
    return orden, padre, epadre, en_arbol
end

# ------------------------------------------------------------------------------
# Métricas
# ------------------------------------------------------------------------------

"""
    calcular_metricas_avanzadas(grafo; longitud_min_tortuosidad_mm=5.0) -> Dict

Ver la cabecera del archivo. `longitud_min_tortuosidad_mm`: las aristas más cortas que esto no entran en
los estadísticos de tortuosidad (pocos vóxeles → valor ruidoso: el cociente arco/cuerda de un tramo de
2–3 vóxeles está dominado por la discretización).
"""
function calcular_metricas_avanzadas(grafo; longitud_min_tortuosidad_mm::Float64=5.0)
    g = _plano(grafo)
    todas = 1:g.m

    # ---- estadísticos por arista ----------------------------------------------------
    tort_idx = Int[e for e in todas if isfinite(g.T[e]) && isfinite(g.L[e]) && g.L[e] >= longitud_min_tortuosidad_mm]
    tort = Float64[g.T[e] for e in tort_idx]
    aristas = Dict{String,Any}(
        "radio" => _estadisticos(g.R),
        "longitud" => _estadisticos(g.L),
        "tortuosidad" => _estadisticos(tort),
        "radio_ponderado" => _media_ponderada(g.R, g.L),
        "tortuosidad_ponderada" => _media_ponderada(tort, Float64[g.L[e] for e in tort_idx]),
    )

    # ---- geometría global -----------------------------------------------------------
    vol = 0.0
    sup = 0.0
    for e in todas
        if isfinite(g.R[e]) && isfinite(g.L[e])
            vol += pi * g.R[e]^2 * g.L[e]
            sup += 2 * pi * g.R[e] * g.L[e]
        end
    end

    # ---- topología ------------------------------------------------------------------
    gr = g.grado
    n_bif = count(x -> x >= 3, gr)
    topologia = Dict{String,Any}(
        "nodos_grado1" => count(x -> x == 1, gr),
        "nodos_grado3" => count(x -> x == 3, gr),
        "nodos_grado4" => count(x -> x == 4, gr),
        "nodos_grado5mas" => count(x -> x >= 5, gr),
        "fraccion_trifurcaciones" => n_bif > 0 ? count(x -> x >= 4, gr) / n_bif : nothing,
    )

    # ---- jerarquía, bifurcaciones y caminos: por componente ---------------------------
    gen_aristas = Int[]
    gen_terminales = Int[]
    corr_orden = Int[]
    corr_long = Float64[]
    corr_rad = Float64[]
    strahler_max = 0
    ang_hijas = Float64[]
    ang_mayor = Float64[]
    ang_menor = Float64[]
    razon_rad = Float64[]
    razon_area = Float64[]
    exponentes = Float64[]
    asimetria = Float64[]
    caminos_punta = Float64[]
    rad_term = Float64[]
    rad_int = Float64[]
    long_term = Float64[]
    long_int = Float64[]
    diametros = Float64[]
    wiener_total = 0.0
    pares_total = 0.0
    n_arboles = 0
    fuera = 0

    for nodos in _componentes(g)
        raiz = _elegir_raiz(g, nodos)
        aristas_comp = unique(Int[e for u in nodos for e in g.inc[u]])
        if raiz == 0                              # solo lazos: no hay árbol
            fuera += length(aristas_comp)
            continue
        end
        n_arboles += 1
        orden, padre, epadre, en_arbol = _arbol_generador(g, raiz)
        fuera += length(aristas_comp) - count(en_arbol)

        hijos = [Int[] for _ in 1:g.n]
        for v in orden[2:end]
            push!(hijos[padre[v]], v)
        end

        # orden de Strahler, nº de puntas y de nodos por subárbol (de las hojas hacia la raíz)
        strahler = zeros(Int, g.n)
        tips = zeros(Int, g.n)
        tam = zeros(Int, g.n)
        for v in reverse(orden)
            hs = hijos[v]
            if isempty(hs)
                strahler[v] = 1
                tips[v] = 1
                tam[v] = 1
            else
                m_ord = maximum(strahler[h] for h in hs)
                nmax = count(h -> strahler[h] == m_ord, hs)
                strahler[v] = nmax >= 2 ? m_ord + 1 : m_ord
                tips[v] = sum(tips[h] for h in hs)
                tam[v] = 1 + sum(tam[h] for h in hs)
            end
        end
        strahler_max = max(strahler_max, strahler[raiz])

        # generación (bifurcaciones entre la raíz y la arista), distancia a la raíz, ramas distales/internas
        bc = zeros(Int, g.n)
        dist = zeros(Float64, g.n)
        bc[raiz] = length(hijos[raiz]) >= 2 ? 1 : 0
        for v in orden[2:end]
            p = padre[v]
            e = epadre[v]
            bc[v] = bc[p] + (length(hijos[v]) >= 2 ? 1 : 0)
            dist[v] = dist[p] + _l0(g, e)
            push!(gen_aristas, bc[p])
            if isempty(hijos[v])
                push!(gen_terminales, bc[p])
                push!(caminos_punta, dist[v])
                push!(rad_term, g.R[e])
                push!(long_term, g.L[e])
            else
                push!(rad_int, g.R[e])
                push!(long_int, g.L[e])
            end
        end

        # corrientes de Strahler: cadenas de aristas consecutivas del mismo orden (una corriente se cuenta
        # una sola vez, en su extremo proximal; NO es lo mismo que contar aristas de orden k)
        cL = zeros(Float64, g.n)
        cRL = zeros(Float64, g.n)
        for v in reverse(orden[2:end])
            e = epadre[v]
            l = _l0(g, e)
            rl = isfinite(g.R[e]) ? g.R[e] * l : 0.0
            for h in hijos[v]
                if strahler[h] == strahler[v]
                    l += cL[h]
                    rl += cRL[h]
                end
            end
            cL[v] = l
            cRL[v] = rl
        end
        for v in orden[2:end]
            u = padre[v]
            if u == raiz || strahler[u] != strahler[v]
                push!(corr_orden, strahler[v])
                push!(corr_long, cL[v])
                push!(corr_rad, cL[v] > 0 ? cRL[v] / cL[v] : NaN)
            end
        end

        # geometría de las bifurcaciones binarias
        for v in orden
            hs = hijos[v]
            length(hs) == 2 || continue
            e1 = epadre[hs[1]]
            e2 = epadre[hs[2]]
            d1 = _dir_en(g, e1, v)
            d2 = _dir_en(g, e2, v)
            a = _angulo_grados(d1, d2)
            a !== nothing && push!(ang_hijas, a)
            v == raiz && continue
            ep = epadre[v]
            dp = _dir_en(g, ep, v)
            eje = (-dp[1], -dp[2], -dp[3])                # continuación del padre
            a1 = _angulo_grados(d1, eje)
            a2 = _angulo_grados(d2, eje)
            if a1 !== nothing && a2 !== nothing
                if g.R[e1] >= g.R[e2]
                    push!(ang_mayor, a1)
                    push!(ang_menor, a2)
                else
                    push!(ang_mayor, a2)
                    push!(ang_menor, a1)
                end
            end
            rp = g.R[ep]
            r1 = g.R[e1]
            r2 = g.R[e2]
            if rp > 0 && r1 > 0 && r2 > 0
                push!(razon_rad, min(r1, r2) / max(r1, r2))
                push!(razon_area, (r1^2 + r2^2) / rp^2)
                x = _exponente_union(rp, r1, r2)
                x !== nothing && push!(exponentes, x)
            end
            n1 = tips[hs[1]]
            n2 = tips[hs[2]]
            n1 + n2 > 2 && push!(asimetria, abs(n1 - n2) / (n1 + n2 - 2))
        end

        # diámetro (doble barrido sobre el árbol) y suma de distancias entre todos los pares de nodos
        ady = [Tuple{Int,Float64}[] for _ in 1:g.n]
        for v in orden[2:end]
            w = _l0(g, epadre[v])
            push!(ady[v], (padre[v], w))
            push!(ady[padre[v]], (v, w))
        end
        barrido = function (origen)
            d = fill(-1.0, g.n)
            d[origen] = 0.0
            pila = Int[origen]
            while !isempty(pila)
                u = pop!(pila)
                for (v, w) in ady[u]
                    if d[v] < 0
                        d[v] = d[u] + w
                        push!(pila, v)
                    end
                end
            end
            return d
        end
        d0 = barrido(raiz)
        lejano = orden[argmax(Float64[d0[v] for v in orden])]
        da = barrido(lejano)
        push!(diametros, maximum(da[v] for v in orden))
        N = length(orden)
        wiener_total += sum((_l0(g, epadre[v]) * tam[v] * (N - tam[v]) for v in orden[2:end]); init=0.0)
        pares_total += N * (N - 1) / 2
    end

    aristas["radio_terminales"] = _estadisticos(rad_term)["media"]
    aristas["radio_internas"] = _estadisticos(rad_int)["media"]
    aristas["longitud_terminales"] = _estadisticos(long_term)["media"]
    aristas["longitud_internas"] = _estadisticos(long_int)["media"]
    aristas["n_terminales"] = length(rad_term)

    # ---- razones de Horton (regresión de ln N_k, ln l_k, ln r_k contra el orden k) ------------
    ordenes = sort!(unique(corr_orden))
    N_k = Int[count(x -> x == k, corr_orden) for k in ordenes]
    l_k = Any[_estadisticos(corr_long[corr_orden .== k])["media"] for k in ordenes]
    r_k = Any[_estadisticos(corr_rad[corr_orden .== k])["media"] for k in ordenes]
    sN = _pendiente_log(ordenes, N_k)
    sl = _pendiente_log(ordenes, l_k)
    sr = _pendiente_log(ordenes, r_k)
    por_orden(vals) = Dict{String,Any}(string(k) => vals[i] for (i, k) in enumerate(ordenes))

    jerarquia = Dict{String,Any}(
        "n_arboles" => n_arboles,
        "aristas_fuera_del_arbol" => fuera,
        "generacion_max" => isempty(gen_aristas) ? nothing : maximum(gen_aristas),
        "generacion_media_puntas" => isempty(gen_terminales) ? nothing : sum(gen_terminales) / length(gen_terminales),
        "strahler_max" => n_arboles > 0 ? strahler_max : nothing,
        "n_por_orden" => por_orden(N_k),
        "longitud_media_por_orden" => por_orden(l_k),
        "radio_medio_por_orden" => por_orden(r_k),
        "razon_bifurcacion" => sN === nothing ? nothing : exp(-sN),
        "razon_longitud" => sl === nothing ? nothing : exp(sl),
        "razon_radio" => sr === nothing ? nothing : exp(sr),
    )
    bifurcaciones = Dict{String,Any}(
        "n_binarias" => length(ang_hijas),
        "angulo_hijas" => _estadisticos(ang_hijas),
        "angulo_hija_mayor" => _estadisticos(ang_mayor),
        "angulo_hija_menor" => _estadisticos(ang_menor),
        "razon_radios_hijas" => _estadisticos(razon_rad),
        "razon_area" => _estadisticos(razon_area),
        "exponente_union" => _estadisticos(exponentes),
        "asimetria_particion" => _estadisticos(asimetria),
    )
    caminos = Dict{String,Any}(
        "raiz_punta" => _estadisticos(caminos_punta),
        "diametro_mm" => isempty(diametros) ? nothing : maximum(diametros),
        "camino_medio_mm" => pares_total > 0 ? wiener_total / pares_total : nothing,
    )
    estructura = Dict{String,Any}(
        "aristas" => aristas,
        "geometria" => Dict{String,Any}("volumen_vascular_mm3" => vol, "superficie_vascular_mm2" => sup),
        "topologia" => topologia,
        "jerarquia" => jerarquia,
        "bifurcaciones" => bifurcaciones,
        "caminos" => caminos,
    )
    return Dict{String,Any}(
        "estructura" => estructura,
        "caracteristicas" => _caracteristicas_planas(estructura),
        "histogramas" => Dict{String,Any}(
            "radio_mm" => _histograma(g.R),
            "longitud_mm" => _histograma(g.L),
            "tortuosidad" => _histograma(tort),
        ),
    )
end

# ------------------------------------------------------------------------------
# Características planas (una fila de la tabla sujeto × característica)
# ------------------------------------------------------------------------------

"""Nombres de las características planas, en el orden en que se escriben en el Excel y se muestran."""
const ORDEN_CARACTERISTICAS_GRAFOS = String[
    "radio_media_mm", "radio_sd_mm", "radio_mediana_mm", "radio_p10_mm", "radio_p90_mm", "radio_max_mm",
    "radio_ponderado_mm", "radio_terminales_media_mm", "radio_internas_media_mm",
    "longitud_media_mm", "longitud_sd_mm", "longitud_mediana_mm", "longitud_p10_mm", "longitud_p90_mm", "longitud_max_mm",
    "longitud_terminales_media_mm", "longitud_internas_media_mm",
    "tortuosidad_media", "tortuosidad_sd", "tortuosidad_mediana", "tortuosidad_p10", "tortuosidad_p90", "tortuosidad_max",
    "tortuosidad_ponderada", "tortuosidad_n_aristas",
    "volumen_vascular_mm3", "superficie_vascular_mm2",
    "nodos_grado1", "nodos_grado3", "nodos_grado4", "nodos_grado5mas", "fraccion_trifurcaciones",
    "n_arboles", "aristas_fuera_del_arbol", "generacion_max", "generacion_media_puntas", "strahler_max",
    "razon_bifurcacion_horton", "razon_longitud_horton", "razon_radio_horton",
    "n_bifurcaciones_binarias", "angulo_hijas_media_deg", "angulo_hijas_sd_deg", "angulo_hija_mayor_media_deg",
    "angulo_hija_menor_media_deg", "razon_radios_hijas_media", "razon_area_media", "exponente_union_mediano",
    "exponente_union_media", "asimetria_particion_media",
    "camino_raiz_punta_media_mm", "camino_raiz_punta_max_mm", "diametro_mm", "camino_medio_mm",
]

function _caracteristicas_planas(est)
    A = est["aristas"]
    J = est["jerarquia"]
    B = est["bifurcaciones"]
    C = est["caminos"]
    c = Dict{String,Any}()
    pon!(clave, valor) = (c[clave] = _numero_json(valor))

    for (pref, sufijo, s) in (("radio", "_mm", A["radio"]), ("longitud", "_mm", A["longitud"]), ("tortuosidad", "", A["tortuosidad"]))
        pon!("$(pref)_media$(sufijo)", s["media"])
        pon!("$(pref)_sd$(sufijo)", s["sd"])
        pon!("$(pref)_mediana$(sufijo)", s["mediana"])
        pon!("$(pref)_p10$(sufijo)", s["p10"])
        pon!("$(pref)_p90$(sufijo)", s["p90"])
        pon!("$(pref)_max$(sufijo)", s["max"])
    end
    pon!("radio_ponderado_mm", A["radio_ponderado"])
    pon!("radio_terminales_media_mm", A["radio_terminales"])
    pon!("radio_internas_media_mm", A["radio_internas"])
    pon!("longitud_terminales_media_mm", A["longitud_terminales"])
    pon!("longitud_internas_media_mm", A["longitud_internas"])
    pon!("tortuosidad_ponderada", A["tortuosidad_ponderada"])
    pon!("tortuosidad_n_aristas", A["tortuosidad"]["n"])

    pon!("volumen_vascular_mm3", est["geometria"]["volumen_vascular_mm3"])
    pon!("superficie_vascular_mm2", est["geometria"]["superficie_vascular_mm2"])
    for k in ("nodos_grado1", "nodos_grado3", "nodos_grado4", "nodos_grado5mas", "fraccion_trifurcaciones")
        pon!(k, est["topologia"][k])
    end

    pon!("n_arboles", J["n_arboles"])
    pon!("aristas_fuera_del_arbol", J["aristas_fuera_del_arbol"])
    pon!("generacion_max", J["generacion_max"])
    pon!("generacion_media_puntas", J["generacion_media_puntas"])
    pon!("strahler_max", J["strahler_max"])
    pon!("razon_bifurcacion_horton", J["razon_bifurcacion"])
    pon!("razon_longitud_horton", J["razon_longitud"])
    pon!("razon_radio_horton", J["razon_radio"])

    pon!("n_bifurcaciones_binarias", B["n_binarias"])
    pon!("angulo_hijas_media_deg", B["angulo_hijas"]["media"])
    pon!("angulo_hijas_sd_deg", B["angulo_hijas"]["sd"])
    pon!("angulo_hija_mayor_media_deg", B["angulo_hija_mayor"]["media"])
    pon!("angulo_hija_menor_media_deg", B["angulo_hija_menor"]["media"])
    pon!("razon_radios_hijas_media", B["razon_radios_hijas"]["media"])
    pon!("razon_area_media", B["razon_area"]["media"])
    pon!("exponente_union_mediano", B["exponente_union"]["mediana"])
    pon!("exponente_union_media", B["exponente_union"]["media"])
    pon!("asimetria_particion_media", B["asimetria_particion"]["media"])

    pon!("camino_raiz_punta_media_mm", C["raiz_punta"]["media"])
    pon!("camino_raiz_punta_max_mm", C["raiz_punta"]["max"])
    pon!("diametro_mm", C["diametro_mm"])
    pon!("camino_medio_mm", C["camino_medio_mm"])
    return c
end

# ==============================================================================
# AUTOPRUEBA — grafos armados a mano con respuesta analítica conocida (sin imágenes).
#   julia --project=. -e 'include("MetricasGrafos.jl"); autoprueba_metricas()'
# Los valores esperados salen de docs/referencia/prototipo_metricas.py.
# ==============================================================================

"""Grafo en el formato del análisis. `aristas`: tuplas (u, v, L, R, dir_u, dir_v) con nodos 1..n; dir_* pueden ser `nothing`."""
function _g_construir(grados::Vector{Int}, aristas)
    nodos = Any[Dict{String,Any}("id" => i, "tipo" => "x", "grado" => gr) for (i, gr) in enumerate(grados)]
    A = Any[]
    for (k, (u, v, L, R, du, dv)) in enumerate(aristas)
        push!(A, Dict{String,Any}("id" => k, "u" => u, "v" => v, "longitud_mm" => L, "radio_medio_mm" => R,
                                  "tortuosidad" => 1.0, "n_voxeles" => 10,
                                  "dir_u" => du === nothing ? nothing : collect(du),
                                  "dir_v" => dv === nothing ? nothing : collect(dv)))
    end
    return Dict{String,Any}("nodos" => nodos, "aristas" => A)
end

"""Raíz (punta) → bifurcación b0 → 2 bifurcaciones → 4 puntas; ramas a ±30° del eje del padre (60° entre hijas)."""
function _arbol_binario_perfecto()
    s30 = sin(deg2rad(30)); c30 = cos(deg2rad(30))
    s60 = sin(deg2rad(60)); c60 = cos(deg2rad(60))
    opuesto(a) = (-a[1], -a[2], -a[3])
    e1 = (1, 2, 10.0, 4.0, (0.0, 0.0, 1.0), (0.0, 0.0, -1.0))
    a2 = (-s30, 0.0, c30); e2 = (2, 3, 7.0, 3.0, a2, opuesto(a2))
    a3 = (s30, 0.0, c30);  e3 = (2, 4, 7.0, 3.0, a3, opuesto(a3))
    a4 = (-s60, 0.0, c60); e4 = (3, 5, 5.0, 2.0, a4, opuesto(a4))
    a5 = (0.0, 0.0, 1.0);  e5 = (3, 6, 5.0, 2.0, a5, opuesto(a5))
    a6 = (s60, 0.0, c60);  e6 = (4, 7, 5.0, 2.0, a6, opuesto(a6))
    a7 = (0.0, 0.0, 1.0);  e7 = (4, 8, 5.0, 2.0, a7, opuesto(a7))
    return _g_construir([1, 3, 3, 3, 1, 1, 1, 1], [e1, e2, e3, e4, e5, e6, e7])
end

"""Distancia media entre todos los pares de nodos y diámetro, por fuerza bruta (Floyd-Warshall)."""
function _wiener_fuerza_bruta(grafo)
    n = length(grafo["nodos"])
    D = fill(Inf, n, n)
    for i in 1:n
        D[i, i] = 0.0
    end
    for a in grafo["aristas"]
        u = a["u"]; v = a["v"]; w = Float64(a["longitud_mm"])
        D[u, v] = min(D[u, v], w)
        D[v, u] = min(D[v, u], w)
    end
    for k in 1:n, i in 1:n, j in 1:n
        if D[i, k] + D[k, j] < D[i, j]
            D[i, j] = D[i, k] + D[k, j]
        end
    end
    suma = 0.0
    maximo = 0.0
    for i in 1:n, j in i+1:n
        suma += D[i, j]
        maximo = max(maximo, D[i, j])
    end
    return suma / (n * (n - 1) / 2), maximo
end

function autoprueba_metricas()
    ok = true
    chequear = function (nombre, cond)
        println(cond ? "  ✅ " : "  ❌ ", nombre)
        return cond
    end
    cerca(a, b, tol=1e-9) = a !== nothing && abs(a - b) <= tol
    println("Autoprueba de las métricas avanzadas de grafos")

    # 1) Árbol binario perfecto de 2 niveles
    g1 = _arbol_binario_perfecto()
    M = calcular_metricas_avanzadas(g1)
    E = M["estructura"]
    J = E["jerarquia"]; B = E["bifurcaciones"]; C = E["caminos"]; A = E["aristas"]
    ok &= chequear("jerarquía: 1 árbol, Strahler 3, generación máx 2 (puntas en gen 2)",
                   J["n_arboles"] == 1 && J["strahler_max"] == 3 && J["generacion_max"] == 2 && cerca(J["generacion_media_puntas"], 2.0))
    ok &= chequear("corrientes por orden N = (4, 2, 1)", J["n_por_orden"] == Dict{String,Any}("1" => 4, "2" => 2, "3" => 1))
    ok &= chequear("razón de bifurcación de Horton = 2", cerca(J["razon_bifurcacion"], 2.0))
    ok &= chequear("razón de longitud = razón de radio = √2", cerca(J["razon_longitud"], sqrt(2.0)) && cerca(J["razon_radio"], sqrt(2.0)))
    ok &= chequear("3 bifurcaciones binarias; ángulo entre hijas = 60°; hija–eje = 30°",
                   B["n_binarias"] == 3 && cerca(B["angulo_hijas"]["media"], 60.0, 1e-7) &&
                   cerca(B["angulo_hija_mayor"]["media"], 30.0, 1e-7) && cerca(B["angulo_hija_menor"]["media"], 30.0, 1e-7))
    ok &= chequear("razón de radios de las hijas = 1; razón de área media = (18/16 + 2·8/9)/3",
                   cerca(B["razon_radios_hijas"]["media"], 1.0) && cerca(B["razon_area"]["media"], (18 / 16 + 2 * 8 / 9) / 3))
    x0 = log(0.5) / log(0.75)
    x1 = log(0.5) / log(2 / 3)
    ok &= chequear("exponente de unión: 2.409 en la raíz y 1.710 en las otras dos",
                   cerca(B["exponente_union"]["mediana"], x1, 1e-7) && cerca(B["exponente_union"]["media"], (x0 + 2 * x1) / 3, 1e-7))
    ok &= chequear("asimetría de partición: solo una bifurcación con más de 2 puntas, vale 0",
                   B["asimetria_particion"]["n"] == 1 && cerca(B["asimetria_particion"]["media"], 0.0))
    ok &= chequear("camino raíz→punta = 22 en las 4 puntas; diámetro = 24",
                   C["raiz_punta"]["n"] == 4 && cerca(C["raiz_punta"]["media"], 22.0) && cerca(C["diametro_mm"], 24.0))
    wiener_bf, diam_bf = _wiener_fuerza_bruta(g1)
    ok &= chequear("camino medio (fórmula O(V) en árbol) = fuerza bruta ($(C["camino_medio_mm"]) vs $(wiener_bf))",
                   cerca(C["camino_medio_mm"], wiener_bf) && cerca(diam_bf, 24.0))
    ok &= chequear("volumen = 366π y superficie = 244π",
                   cerca(E["geometria"]["volumen_vascular_mm3"], 366 * pi, 1e-6) && cerca(E["geometria"]["superficie_vascular_mm2"], 244 * pi, 1e-6))
    radios = [4.0, 3.0, 3.0, 2.0, 2.0, 2.0, 2.0]
    media_r = sum(radios) / 7
    sd_r = sqrt(sum((x - media_r)^2 for x in radios) / 6)
    ok &= chequear("estadísticos de radio: media, sd, mediana = 2, p10 = 2, p90 = 3.4",
                   cerca(A["radio"]["media"], media_r) && cerca(A["radio"]["sd"], sd_r) && cerca(A["radio"]["mediana"], 2.0) &&
                   cerca(A["radio"]["p10"], 2.0) && cerca(A["radio"]["p90"], 3.4))
    ok &= chequear("ramas distales vs internas: radio 2 vs 10/3 (el tronco de entrada es interna); 4 distales",
                   cerca(A["radio_terminales"], 2.0) && cerca(A["radio_internas"], 10 / 3) && A["n_terminales"] == 4)
    h = M["histogramas"]["radio_mm"]
    ok &= chequear("histograma de radios: 20 clases que suman 7", length(h["conteos"]) == 20 && sum(h["conteos"]) == 7)
    ok &= chequear("todas las características planas existen (y son números o null)",
                   all(k -> haskey(M["caracteristicas"], k), ORDEN_CARACTERISTICAS_GRAFOS) &&
                   length(M["caracteristicas"]) == length(ORDEN_CARACTERISTICAS_GRAFOS))

    # 2) Corrientes de Strahler ≠ aristas de orden k
    g2 = _g_construir([1, 3, 1, 3, 1, 1], [(1, 2, 8.0, 3.0, nothing, nothing), (2, 3, 6.0, 1.5, nothing, nothing),
                                           (2, 4, 6.0, 2.5, nothing, nothing), (4, 5, 4.0, 1.5, nothing, nothing),
                                           (4, 6, 4.0, 1.5, nothing, nothing)])
    E2 = calcular_metricas_avanzadas(g2)["estructura"]
    J2 = E2["jerarquia"]
    ok &= chequear("Strahler 2; N = (3, 1): las dos aristas de orden 2 forman UNA corriente",
                   J2["strahler_max"] == 2 && J2["n_por_orden"] == Dict{String,Any}("1" => 3, "2" => 1))
    ok &= chequear("longitud de la corriente de orden 2 = 8 + 6 = 14; razón de bifurcación = 3",
                   cerca(J2["longitud_media_por_orden"]["2"], 14.0) && cerca(J2["razon_bifurcacion"], 3.0))
    ok &= chequear("asimetría de partición = |1−2|/(3−2) = 1; sin direcciones no hay ángulos",
                   E2["bifurcaciones"]["asimetria_particion"]["n"] == 1 && cerca(E2["bifurcaciones"]["asimetria_particion"]["media"], 1.0) &&
                   E2["bifurcaciones"]["angulo_hijas"]["n"] == 0)

    # 3) Elección de la raíz
    g3 = _g_construir([1, 3, 3, 3, 1, 1, 1, 1], [(1, 2, 4.0, 2.0, nothing, nothing), (2, 3, 12.0, 5.0, nothing, nothing),
                                                 (2, 5, 6.0, 1.0, nothing, nothing), (3, 4, 6.0, 2.0, nothing, nothing),
                                                 (3, 6, 6.0, 2.0, nothing, nothing), (4, 7, 6.0, 1.0, nothing, nothing),
                                                 (4, 8, 6.0, 1.0, nothing, nothing)])
    p3 = _plano(g3)
    ok &= chequear("raíz = extremo de la arista más gruesa con menos grafo detrás (nodo 2: 10 mm detrás vs 24 mm)",
                   _elegir_raiz(p3, _componentes(p3)[1]) == 2)
    g3b = _g_construir([1, 3, 1, 1], [(1, 2, 1.0, 9.0, nothing, nothing), (2, 3, 10.0, 2.0, nothing, nothing), (2, 4, 10.0, 2.0, nothing, nothing)])
    p3b = _plano(g3b)
    ok &= chequear("una arista corta (< 2 radios) con radio inflado no decide la raíz (queda el nodo 3)",
                   _elegir_raiz(p3b, _componentes(p3b)[1]) == 3)

    # 4) Ciclos, varias componentes, casos vacíos
    g4 = _g_construir([3, 2, 2, 1, 1, 1], [(1, 2, 5.0, 1.0, nothing, nothing), (2, 3, 5.0, 1.0, nothing, nothing),
                                           (3, 1, 5.0, 1.0, nothing, nothing), (1, 4, 8.0, 2.0, nothing, nothing),
                                           (5, 6, 7.0, 1.0, nothing, nothing)])
    J4 = calcular_metricas_avanzadas(g4)["estructura"]["jerarquia"]
    ok &= chequear("triángulo con cola + otra componente: 2 árboles y 1 arista fuera del árbol",
                   J4["n_arboles"] == 2 && J4["aristas_fuera_del_arbol"] == 1)
    ok &= chequear("lazo propio solo: sin árbol y sin error",
                   calcular_metricas_avanzadas(_g_construir([2], [(1, 1, 9.0, 1.0, nothing, nothing)]))["estructura"]["jerarquia"]["n_arboles"] == 0)
    ok &= chequear("grafo vacío: sin error ni valores",
                   calcular_metricas_avanzadas(Dict{String,Any}("nodos" => Any[], "aristas" => Any[]))["estructura"]["aristas"]["radio"]["n"] == 0)

    # 5) Exponente de unión (Murray)
    ok &= chequear("hijas de radio r·2^(−1/3) dan x = 3 (ley de Murray)", cerca(_exponente_union(1.0, 2.0^(-1 / 3), 2.0^(-1 / 3)), 3.0))
    ok &= chequear("sin solución si alguna hija >= padre", _exponente_union(1.0, 1.0, 0.5) === nothing && _exponente_union(1.0, 1.2, 0.5) === nothing)

    println(ok ? "✅ Autoprueba de métricas: todo en orden" : "❌ Autoprueba de métricas: HAY FALLOS")
    return ok
end
