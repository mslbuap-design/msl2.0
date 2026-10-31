# ==============================================================================
# ComparacionGrupos.jl — Comparación estadística entre grupos (Fase 3B)
# ==============================================================================
#
# Entrada: una fila por SUJETO con sus características planas (las 54 de
# `MetricasGrafos.jl`) y el grupo al que pertenece. Salida: por característica, la
# comparación entre grupos con prueba principal, tamaño de efecto y corrección por
# comparaciones múltiples (ver `comparar_grupos`).
#
# La unidad de análisis es el SUJETO: un valor por sujeto y característica. Las aristas
# de un mismo árbol no son independientes, así que nunca se comparan aristas sueltas
# con pruebas de grupos.
#
# Convención de orientación (la misma que en la interfaz): en una comparación entre dos
# grupos, `x` es el grupo COMPARADO (el que se lista después) e `y` la REFERENCIA (el que
# se lista primero). Todo efecto se lee "x frente a y":
#   AUC = P(X > Y) + ½·P(X = Y);  δ de Cliff = 2·AUC − 1;  g de Hedges = (media_x − media_y)/s_agrupada.
# δ > 0 (o g > 0) = el grupo comparado tiende a valores MAYORES que la referencia.
# Con más de dos grupos, cada par (a, b), con a listado antes que b, se orienta como b frente a a.
#
# Pruebas (todas bilaterales):
#   no paramétrica: Mann–Whitney U (2 grupos; p exacto sin empates y n₁+n₂ ≤ 40, si no normal con
#                   corrección por empates y continuidad) y Kruskal–Wallis H (>2 grupos).
#   paramétrica:    t de Welch (2 grupos) y ANOVA de Welch (>2 grupos).
# Siempre se calculan las dos familias; la elegida como principal es la que entra en la corrección por
# comparaciones múltiples (Benjamini–Hochberg; Holm se informa al lado). No se elige la prueba según
# Shapiro–Wilk (poca potencia con n chico, y el "test-then-test" infla el error).
#
# Solo usa `Distributions` (TDist, Chisq, FDist, Normal): nada de `HypothesisTests`. Estos
# algoritmos se escribieron y verificaron primero en docs/TestGraph/prototipo_comparacion.py
# (contra scipy y por simulación); este código es el port de esa lógica. Autoprueba:
#   julia --project=. -e 'include("ComparacionGrupos.jl"); autoprueba_comparacion()'
# ==============================================================================

using Distributions
using JSON3

"""Cuantil 0,975 de la normal estándar (para los IC del 95 %)."""
const CG_Z975 = 1.959963984540054

# ------------------------------------------------------------------------------
# Utilidades
# ------------------------------------------------------------------------------

"""¿Es un número finito (y no un booleano)?"""
_cg_finito(x) = x isa Real && !(x isa Bool) && isfinite(x)

"""Los valores que son números finitos, como `Float64` (se descartan `nothing`, NaN, ±Inf y lo que no es número)."""
function cg_finitos(valores)
    return Float64[Float64(x) for x in valores if _cg_finito(x)]
end

_cg_media(v) = sum(v) / length(v)

"""Varianza muestral (n−1). Requiere `length(v) >= 2`."""
function _cg_varianza(v)
    m = _cg_media(v)
    s = 0.0
    for x in v
        s += (x - m)^2
    end
    return s / (length(v) - 1)
end

"""Percentil `p` (0..1) de un vector ORDENADO, con interpolación lineal (igual que `numpy.percentile`)."""
function _cg_percentil(s::Vector{Float64}, p::Float64)
    n = length(s)
    pos = p * (n - 1)
    lo = floor(Int, pos)
    hi = min(lo + 1, n - 1)
    return s[lo+1] + (pos - lo) * (s[hi+1] - s[lo+1])
end

"""n, mediana, p25, p75, media y desviación estándar muestral (`nothing` si n < 2)."""
function cg_descriptivos(v::Vector{Float64})
    n = length(v)
    if n == 0
        return Dict{String,Any}("n" => 0, "mediana" => nothing, "p25" => nothing, "p75" => nothing,
                                "media" => nothing, "sd" => nothing)
    end
    s = sort(v)
    return Dict{String,Any}("n" => n, "mediana" => _cg_percentil(s, 0.5), "p25" => _cg_percentil(s, 0.25),
                            "p75" => _cg_percentil(s, 0.75), "media" => _cg_media(s),
                            "sd" => n > 1 ? sqrt(_cg_varianza(s)) : nothing)
end

"""Rangos medios (los empates reciben el promedio de sus posiciones) y los tamaños de los grupos de empate."""
function cg_rangos(valores::Vector{Float64})
    n = length(valores)
    orden = sortperm(valores)
    r = zeros(Float64, n)
    empates = Int[]
    i = 1
    while i <= n
        j = i
        while j < n && valores[orden[j+1]] == valores[orden[i]]
            j += 1
        end
        medio = (i + j) / 2
        for k in i:j
            r[orden[k]] = medio
        end
        if j > i
            push!(empates, j - i + 1)
        end
        i = j + 1
    end
    return r, empates
end

"""Σ(t³ − t) sobre los tamaños de los grupos de empate."""
function _cg_termino_empates(empates)
    s = 0.0
    for t in empates
        s += Float64(t)^3 - t
    end
    return s
end

# ------------------------------------------------------------------------------
# Mann–Whitney
# ------------------------------------------------------------------------------

"""Conteo de ordenamientos con U = u, u = 0..m·n (sin empates): c(m,n,u) = c(m−1,n,u−n) + c(m,n−1,u).
Devuelve un vector de largo m·n+1 (el índice 1 corresponde a u = 0)."""
function cg_dist_u(m::Int, n::Int)
    c = Matrix{Vector{Int64}}(undef, m + 1, n + 1)
    for i in 0:m
        for j in 0:n
            if i == 0 || j == 0
                c[i+1, j+1] = Int64[1]
            else
                fila = zeros(Int64, i * j + 1)
                a = c[i, j+1]        # c(i−1, j), desplazado j posiciones
                for (u, v) in enumerate(a)
                    fila[u+j] += v
                end
                b = c[i+1, j]        # c(i, j−1)
                for (u, v) in enumerate(b)
                    fila[u] += v
                end
                c[i+1, j+1] = fila
            end
        end
    end
    return c[m+1, n+1]
end

"""p bilateral exacto de U (entero) = 2·mín(P(U ≤ u), P(U ≥ u)), con tope 1."""
function cg_p_u_exacto(u::Float64, m::Int, n::Int)
    conteos = cg_dist_u(m, n)
    total = sum(conteos)
    k = round(Int, u)
    baja = sum(conteos[1:k+1]) / total
    alta = sum(conteos[k+1:end]) / total
    return min(1.0, 2.0 * min(baja, alta))
end

"""log C(n, k) sin desbordar."""
function _cg_log_binomial(n::Int, k::Int)
    kk = min(k, n - k)
    s = 0.0
    for i in 1:kk
        s += log((n - kk + i) / i)
    end
    return s
end

"""Menor p bilateral que puede alcanzar Mann–Whitney sin empates: 2 / C(n₁+n₂, n₁), con tope 1.
Con n₁ = n₂ = 3 es 0,1: nunca puede salir "significativo"."""
cg_p_minimo_posible(n1::Int, n2::Int) = min(1.0, exp(log(2.0) - _cg_log_binomial(n1 + n2, n1)))

"""Mann–Whitney bilateral de `x` (comparado) frente a `y` (referencia). `estadistico` = U de x
(pares con x > y, con ½ por empate) = R_x − n_x(n_x+1)/2. Exacto si no hay empates y n₁+n₂ ≤ 40;
si no, aproximación normal con corrección por empates y por continuidad."""
function cg_mann_whitney(x::Vector{Float64}, y::Vector{Float64})
    n1 = length(x)
    n2 = length(y)
    r, empates = cg_rangos(vcat(x, y))
    u1 = sum(r[1:n1]) - n1 * (n1 + 1) / 2
    N = n1 + n2
    p = 1.0
    metodo = "exacto"
    if isempty(empates) && N <= 40
        p = cg_p_u_exacto(u1, n1, n2)
    else
        metodo = "asintótico"
        s2 = n1 * n2 / 12.0 * ((N + 1) - _cg_termino_empates(empates) / (N * (N - 1)))
        if s2 > 0
            u = max(u1, n1 * n2 - u1)
            z = (u - n1 * n2 / 2.0 - 0.5) / sqrt(s2)
            p = min(1.0, 2.0 * ccdf(Normal(), z))
        end
    end
    return Dict{String,Any}("nombre" => "Mann–Whitney U", "estadistico" => u1, "gl" => nothing, "p" => p, "metodo" => metodo)
end

# ------------------------------------------------------------------------------
# AUC, δ de Cliff e IC de DeLong
# ------------------------------------------------------------------------------

"""AUC = P(X>Y)+½P(X=Y) y su IC 95 % (varianza de DeLong, intervalo en escala logit).
El IC es `nothing` si no es estimable (AUC = 0 ó 1, o error estándar 0)."""
function cg_auc_delong(x::Vector{Float64}, y::Vector{Float64})
    m = length(x)
    n = length(y)
    v10 = zeros(Float64, m)
    v01 = zeros(Float64, n)
    for i in 1:m
        for j in 1:n
            psi = x[i] > y[j] ? 1.0 : (x[i] == y[j] ? 0.5 : 0.0)
            v10[i] += psi
            v01[j] += psi
        end
    end
    v10 ./= n
    v01 ./= m
    auc = sum(v10) / m
    varianza_auc = _cg_varianza(v10) / m + _cg_varianza(v01) / n
    se = sqrt(varianza_auc)
    if auc <= 0.0 || auc >= 1.0 || se == 0.0
        return auc, nothing
    end
    theta = log(auc / (1 - auc))
    se_l = se / (auc * (1 - auc))
    lo = 1 / (1 + exp(-(theta - CG_Z975 * se_l)))
    hi = 1 / (1 + exp(-(theta + CG_Z975 * se_l)))
    return auc, (lo, hi)
end

"""AUC, δ de Cliff y sus IC 95 % (el IC de δ es 2·IC(AUC) − 1)."""
function cg_efecto_rangos(x::Vector{Float64}, y::Vector{Float64})
    auc, ic = cg_auc_delong(x, y)
    return Dict{String,Any}("auc" => auc,
                            "auc_ic" => ic === nothing ? nothing : Any[ic[1], ic[2]],
                            "cliff_delta" => 2 * auc - 1,
                            "cliff_ic" => ic === nothing ? nothing : Any[2 * ic[1] - 1, 2 * ic[2] - 1])
end

# ------------------------------------------------------------------------------
# Welch y g de Hedges
# ------------------------------------------------------------------------------

"""t de Welch de `x` frente a `y`, gl de Welch–Satterthwaite y p bilateral. `nothing` si el error estándar es 0."""
function cg_welch_t(x::Vector{Float64}, y::Vector{Float64})
    n1 = length(x)
    n2 = length(y)
    a = _cg_varianza(x) / n1
    b = _cg_varianza(y) / n2
    if a + b <= 0
        return nothing
    end
    t = (_cg_media(x) - _cg_media(y)) / sqrt(a + b)
    gl = (a + b)^2 / (a^2 / (n1 - 1) + b^2 / (n2 - 1))
    p = 2.0 * ccdf(TDist(gl), abs(t))
    return Dict{String,Any}("nombre" => "t de Welch", "estadistico" => t, "gl" => gl, "p" => p, "metodo" => nothing)
end

"""g de Hedges (x frente a y) con su IC 95 % aproximado. `nothing` si la desviación agrupada es 0."""
function cg_hedges_g(x::Vector{Float64}, y::Vector{Float64})
    n1 = length(x)
    n2 = length(y)
    sp2 = ((n1 - 1) * _cg_varianza(x) + (n2 - 1) * _cg_varianza(y)) / (n1 + n2 - 2)
    if sp2 <= 0
        return nothing
    end
    d = (_cg_media(x) - _cg_media(y)) / sqrt(sp2)
    g = (1 - 3.0 / (4 * (n1 + n2) - 9)) * d
    se = sqrt((n1 + n2) / (n1 * n2) + g * g / (2.0 * (n1 + n2)))
    return Dict{String,Any}("hedges_g" => g, "hedges_ic" => Any[g - CG_Z975 * se, g + CG_Z975 * se])
end

# ------------------------------------------------------------------------------
# Más de dos grupos
# ------------------------------------------------------------------------------

"""Kruskal–Wallis: H corregido por empates y p = chi²(k−1). Devuelve `(prueba, ε²)` con ε² = H/(N−1)."""
function cg_kruskal_wallis(grupos)
    todos = reduce(vcat, grupos)
    N = length(todos)
    k = length(grupos)
    r, empates = cg_rangos(todos)
    h = 0.0
    pos = 0
    for g in grupos
        h += sum(r[pos+1:pos+length(g)])^2 / length(g)
        pos += length(g)
    end
    h = 12.0 / (N * (N + 1)) * h - 3 * (N + 1)
    c = 1.0 - _cg_termino_empates(empates) / (N^3 - N)
    if c <= 0
        return Dict{String,Any}("nombre" => "Kruskal–Wallis H", "estadistico" => 0.0, "gl" => k - 1, "p" => 1.0, "metodo" => nothing), 0.0
    end
    h /= c
    p = ccdf(Chisq(k - 1), h)
    return Dict{String,Any}("nombre" => "Kruskal–Wallis H", "estadistico" => h, "gl" => k - 1, "p" => p, "metodo" => nothing), h / (N - 1)
end

"""ANOVA de Welch (varianzas desiguales). `nothing` si algún grupo tiene varianza 0.
Con k = 2 da F = t² y los mismos gl que `cg_welch_t`."""
function cg_anova_welch(grupos)
    k = length(grupos)
    ns = Int[length(g) for g in grupos]
    ms = Float64[_cg_media(g) for g in grupos]
    vs = Float64[_cg_varianza(g) for g in grupos]
    if any(v -> v <= 0, vs)
        return nothing
    end
    w = Float64[ns[i] / vs[i] for i in 1:k]
    W = sum(w)
    mt = sum(w[i] * ms[i] for i in 1:k) / W
    num = sum(w[i] * (ms[i] - mt)^2 for i in 1:k) / (k - 1)
    lam = sum((1 - w[i] / W)^2 / (ns[i] - 1) for i in 1:k)
    F = num / (1 + 2.0 * (k - 2) / (k * k - 1) * lam)
    gl2 = (k * k - 1) / (3.0 * lam)
    p = ccdf(FDist(k - 1, gl2), F)
    return Dict{String,Any}("nombre" => "ANOVA de Welch F", "estadistico" => F, "gl" => Any[k - 1, gl2], "p" => p, "metodo" => nothing)
end

"""η² = SC_entre / SC_total (descriptivo, el clásico). `nothing` si no hay variación."""
function cg_eta_cuadrado(grupos)
    todos = reduce(vcat, grupos)
    gm = _cg_media(todos)
    sct = sum((v - gm)^2 for v in todos)
    if sct <= 0
        return nothing
    end
    return sum(length(g) * (_cg_media(g) - gm)^2 for g in grupos) / sct
end

# ------------------------------------------------------------------------------
# Comparaciones múltiples
# ------------------------------------------------------------------------------

"""q de Benjamini–Hochberg: q₍ᵢ₎ = mín_{j≥i} p₍ⱼ₎·m/j, con tope 1 (en el orden original)."""
function cg_benjamini_hochberg(ps::Vector{Float64})
    m = length(ps)
    orden = sortperm(ps)
    q = zeros(Float64, m)
    previo = 1.0
    for rango in m:-1:1
        i = orden[rango]
        previo = min(previo, ps[i] * m / rango)
        q[i] = min(1.0, previo)
    end
    return q
end

"""p ajustado de Holm: p_aj₍ᵢ₎ = máx_{j≤i} (m−j+1)·p₍ⱼ₎, con tope 1 (en el orden original)."""
function cg_holm(ps::Vector{Float64})
    m = length(ps)
    orden = sortperm(ps)
    aj = zeros(Float64, m)
    previo = 0.0
    for rango in 1:m
        i = orden[rango]
        previo = max(previo, (m - rango + 1) * ps[i])
        aj[i] = min(1.0, previo)
    end
    return aj
end

# ------------------------------------------------------------------------------
# Una característica
# ------------------------------------------------------------------------------

"""Grupo con el mayor rango medio al ordenar todos los valores juntos (`nothing` si empatan)."""
function _cg_mayor_en(grupos::Vector{String}, vals::Dict{String,Vector{Float64}})
    todos = reduce(vcat, Vector{Float64}[vals[g] for g in grupos])
    r, _ = cg_rangos(todos)
    medias = Float64[]
    pos = 0
    for g in grupos
        n = length(vals[g])
        push!(medias, sum(r[pos+1:pos+n]) / n)
        pos += n
    end
    mejor = argmax(medias)
    iguales = count(mr -> abs(mr - medias[mejor]) < 1e-9, medias)
    return iguales > 1 ? nothing : grupos[mejor]
end

"""Todo lo de una característica, SIN la corrección por comparaciones múltiples (la hace `comparar_grupos`).
`vals[g]` = valores finitos de cada grupo. `estado`: "ok", "sin_variacion", "omitida" (algún grupo con
menos de 2 sujetos) o "no_estimable" (la prueba principal no se pudo calcular)."""
function cg_comparar_caracteristica(clave::String, grupos::Vector{String}, vals::Dict{String,Vector{Float64}},
                                    prueba_principal::String, alfa::Float64)
    k = length(grupos)
    n_por = Dict{String,Any}(g => length(vals[g]) for g in grupos)
    desc = Dict{String,Any}(g => cg_descriptivos(vals[g]) for g in grupos)
    fila = Dict{String,Any}("clave" => clave, "estado" => "ok", "n" => n_por, "descriptivos" => desc, "mayor_en" => nothing,
                            "prueba_principal" => nothing, "otra_prueba" => nothing, "efecto" => nothing, "p_min_posible" => nothing,
                            "p" => nothing, "q_bh" => nothing, "p_holm" => nothing, "significativa" => false,
                            "pares" => nothing, "nota" => nothing)
    chicos = String[g for g in grupos if length(vals[g]) < 2]
    if !isempty(chicos)
        fila["estado"] = "omitida"
        fila["nota"] = "Se omite: con menos de 2 sujetos en " * join(chicos, ", ") * "."
        return fila
    end
    todos = reduce(vcat, Vector{Float64}[vals[g] for g in grupos])
    if maximum(todos) == minimum(todos)
        fila["estado"] = "sin_variacion"
        fila["p"] = 1.0
        fila["q_bh"] = 1.0
        fila["p_holm"] = 1.0
        fila["nota"] = "Sin variación: todos los sujetos tienen el mismo valor."
        return fila
    end

    fila["mayor_en"] = _cg_mayor_en(grupos, vals)
    notas = String[]
    principal = nothing
    otra = nothing
    if k == 2
        x = vals[grupos[2]]
        y = vals[grupos[1]]
        mw = cg_mann_whitney(x, y)
        wt = cg_welch_t(x, y)
        ef = cg_efecto_rangos(x, y)
        hg = cg_hedges_g(x, y)
        ef["hedges_g"] = hg === nothing ? nothing : hg["hedges_g"]
        ef["hedges_ic"] = hg === nothing ? nothing : hg["hedges_ic"]
        fila["efecto"] = ef
        pmin = cg_p_minimo_posible(length(x), length(y))
        fila["p_min_posible"] = pmin
        if pmin > alfa
            push!(notas, "Con este n el menor p alcanzable ($(round(pmin, sigdigits=3))) supera α: no puede resultar significativa.")
        end
        if prueba_principal == "no_parametrica"
            principal = mw
            otra = wt
        else
            principal = wt
            otra = mw
        end
    else
        gs = Vector{Float64}[vals[g] for g in grupos]
        kw, eps2 = cg_kruskal_wallis(gs)
        aw = cg_anova_welch(gs)
        fila["efecto"] = Dict{String,Any}("epsilon2" => eps2, "eta2" => cg_eta_cuadrado(gs))
        if prueba_principal == "no_parametrica"
            principal = kw
            otra = aw
        else
            principal = aw
            otra = kw
        end
        pares = Dict{String,Any}[]
        for a in 1:k
            for b in a+1:k
                x = vals[grupos[b]]
                y = vals[grupos[a]]
                mw = cg_mann_whitney(x, y)
                ef = cg_efecto_rangos(x, y)
                auc = ef["auc"]
                par = Dict{String,Any}("a" => grupos[a], "b" => grupos[b], "u" => mw["estadistico"], "p" => mw["p"],
                                       "metodo" => mw["metodo"], "p_holm" => nothing,
                                       "mayor_en" => auc == 0.5 ? nothing : (auc > 0.5 ? grupos[b] : grupos[a]))
                merge!(par, ef)
                push!(pares, par)
            end
        end
        holms = cg_holm(Float64[par["p"] for par in pares])
        for (par, ph) in zip(pares, holms)
            par["p_holm"] = ph
        end
        fila["pares"] = pares
    end
    fila["prueba_principal"] = principal
    fila["otra_prueba"] = otra
    if principal === nothing
        fila["estado"] = "no_estimable"
        push!(notas, "La prueba principal no es estimable (varianza cero en algún grupo).")
    else
        fila["p"] = principal["p"]
    end
    if otra === nothing
        push!(notas, "La otra prueba no es estimable (varianza cero en algún grupo).")
    end
    fila["nota"] = isempty(notas) ? nothing : join(notas, " ")
    return fila
end

# ------------------------------------------------------------------------------
# Todas las características
# ------------------------------------------------------------------------------

"""Convierte lo que devuelve `JSON3.read` (objetos con claves Symbol, arreglos propios) en `Dict{String,Any}` / `Vector{Any}` comunes."""
_cg_a_dict(x::AbstractDict) = Dict{String,Any}(string(k) => _cg_a_dict(v) for (k, v) in x)
_cg_a_dict(x::AbstractVector) = Any[_cg_a_dict(v) for v in x]
_cg_a_dict(x) = x

"""Deja la salida lista para JSON: NaN/Inf pasan a `nothing`, las claves a String."""
_cg_limpio(x::AbstractFloat) = isfinite(x) ? x : nothing
_cg_limpio(x::AbstractDict) = Dict{String,Any}(string(k) => _cg_limpio(v) for (k, v) in x)
_cg_limpio(x::AbstractVector) = Any[_cg_limpio(v) for v in x]
_cg_limpio(x::Tuple) = Any[_cg_limpio(v) for v in x]
_cg_limpio(x) = x

"""Claves de las características presentes, en el orden de `ORDEN_CARACTERISTICAS_GRAFOS` (si está cargado) y el resto en orden alfabético."""
function _cg_claves(sujetos)
    presentes = Set{String}()
    for s in sujetos
        c = get(s, "caracteristicas", nothing)
        c isa AbstractDict || continue
        for k in keys(c)
            push!(presentes, String(k))
        end
    end
    orden = isdefined(@__MODULE__, :ORDEN_CARACTERISTICAS_GRAFOS) ? ORDEN_CARACTERISTICAS_GRAFOS : String[]
    claves = String[k for k in orden if k in presentes]
    resto = sort!(String[k for k in presentes if !(k in claves)])
    return vcat(claves, resto)
end

"""
    comparar_grupos(sujetos, grupos, prueba_principal="no_parametrica", alfa=0.05) -> Dict

`sujetos`: `[{"archivo", "grupo", "caracteristicas": {clave: número|null}}]` (un valor por sujeto y característica).
`grupos`: los grupos a comparar, REFERENCIA PRIMERO (≥ 2). `prueba_principal`: "no_parametrica" | "parametrica".

Devuelve `{"resumen": {...}, "resultados": [...]}`. Cada resultado trae `clave`, `estado`, `n` y `descriptivos` por
grupo, `mayor_en`, `prueba_principal`, `otra_prueba`, `efecto` (2 grupos: AUC, δ de Cliff y g de Hedges con sus IC;
>2: ε² y η²), `p_min_posible`, `p` (de la principal), `q_bh` (Benjamini–Hochberg), `p_holm`, `significativa`
(`q_bh ≤ alfa`), `pares` (>2 grupos: Mann–Whitney por pares con Holm dentro de la característica) y `nota`.

La familia de la corrección son las características con `estado == "ok"` (p válido): las que no tienen variación
(p = 1) o no se pueden calcular no cuentan en m. La tabla sale ordenada por q ascendente.
"""
function comparar_grupos(sujetos_in, grupos_in, prueba_principal::AbstractString="no_parametrica", alfa::Real=0.05)
    sujetos = _cg_a_dict(sujetos_in)
    grupos = String[string(g) for g in grupos_in]
    length(grupos) >= 2 || error("Se necesitan al menos 2 grupos para comparar")
    length(unique(grupos)) == length(grupos) || error("Hay grupos repetidos en la selección")
    prueba = String(prueba_principal)
    prueba in ("no_parametrica", "parametrica") || error("prueba_principal inválida: '$prueba' (esperado no_parametrica o parametrica)")
    (alfa > 0 && alfa < 1) || error("alfa debe estar entre 0 y 1")
    alfa_f = Float64(alfa)

    por_grupo = Dict{String,Vector{Any}}(g => Any[] for g in grupos)
    n_sujetos = Dict{String,Any}(g => 0 for g in grupos)
    vistos = Set{Tuple{String,String}}()
    for s in sujetos
        g = string(get(s, "grupo", ""))
        haskey(por_grupo, g) || continue
        a = string(get(s, "archivo", ""))
        if (g, a) in vistos
            error("El sujeto '$a' del grupo '$g' aparece más de una vez: se compara un valor por sujeto")
        end
        push!(vistos, (g, a))
        c = get(s, "caracteristicas", nothing)
        push!(por_grupo[g], c isa AbstractDict ? c : Dict{String,Any}())
        n_sujetos[g] += 1
    end
    for g in grupos
        n_sujetos[g] > 0 || error("El grupo '$g' no tiene sujetos")
    end

    claves = _cg_claves(sujetos)
    filas = Dict{String,Any}[]
    for clave in claves
        vals = Dict{String,Vector{Float64}}()
        for g in grupos
            vals[g] = cg_finitos(Any[get(c, clave, nothing) for c in por_grupo[g]])
        end
        push!(filas, cg_comparar_caracteristica(clave, grupos, vals, prueba, alfa_f))
    end

    familia = Int[i for (i, f) in enumerate(filas) if f["estado"] == "ok"]
    if !isempty(familia)
        ps = Float64[filas[i]["p"] for i in familia]
        qs = cg_benjamini_hochberg(ps)
        hs = cg_holm(ps)
        for (j, i) in enumerate(familia)
            filas[i]["q_bh"] = qs[j]
            filas[i]["p_holm"] = hs[j]
            filas[i]["significativa"] = qs[j] <= alfa_f
        end
    end

    orden_estado = Dict("ok" => 0, "sin_variacion" => 1, "no_estimable" => 2, "omitida" => 3)
    clave_orden = function (i)
        f = filas[i]
        q = f["estado"] == "ok" ? f["q_bh"] : 0.0
        p = f["p"] === nothing ? 2.0 : f["p"]
        return (orden_estado[f["estado"]], q, p, i)
    end
    orden = sort(collect(1:length(filas)); by=clave_orden)

    resumen = Dict{String,Any}("grupos" => grupos, "referencia" => grupos[1], "n_sujetos" => n_sujetos, "m" => length(familia),
                               "n_significativas" => count(f -> f["significativa"] === true, filas),
                               "n_caracteristicas" => length(filas), "alfa" => alfa_f, "prueba_principal" => prueba)
    return _cg_limpio(Dict{String,Any}("resumen" => resumen, "resultados" => Any[filas[i] for i in orden]))
end

# ==============================================================================
# AUTOPRUEBA
# ==============================================================================
# Los valores esperados salen de scipy y del prototipo (docs/TestGraph/prototipo_comparacion.py,
# función `imprimir_esperados`): mannwhitneyu, ttest_ind(equal_var=False), kruskal, false_discovery_control.

"""Catorce sujetos de dos grupos con cinco características: f_a (sin empates), f_b (con empates), f_const (constante),
f_corta (un solo valor en Enfermos) y f_nula (todo vacío). Es la misma tabla que `sujetos_de_prueba()` del prototipo."""
function _cg_sujetos_de_prueba()
    a_x = [4.1, 5.3, 6.8, 7.2, 5.9, 8.4, 6.1]
    a_y = [3.2, 4.4, 5.0, 3.9, 6.0, 4.7]
    b_x = [3.0, 5.0, 5.0, 7.0, 8.0, 8.0, 9.0, 10.0]
    b_y = [2.0, 3.0, 4.0, 4.0, 5.0, 6.0, 6.0, 7.0, 9.0]
    sujetos = Dict{String,Any}[]
    for i in 1:9
        push!(sujetos, Dict{String,Any}("archivo" => "s$(i).nii", "grupo" => "Sanos", "caracteristicas" => Dict{String,Any}(
            "f_a" => i <= length(a_y) ? a_y[i] : nothing, "f_b" => b_y[i], "f_const" => 1.0, "f_corta" => Float64(i - 1), "f_nula" => nothing)))
    end
    for i in 1:8
        push!(sujetos, Dict{String,Any}("archivo" => "e$(i).nii", "grupo" => "Enfermos", "caracteristicas" => Dict{String,Any}(
            "f_a" => i <= length(a_x) ? a_x[i] : nothing, "f_b" => b_x[i], "f_const" => 1.0, "f_corta" => i == 1 ? 5.0 : nothing, "f_nula" => nothing)))
    end
    return sujetos
end

function autoprueba_comparacion()
    ok = true
    chequear = function (nombre, cond)
        println(cond ? "  ✅ " : "  ❌ ", nombre)
        return cond
    end
    cerca(a, b, tol=1e-9) = a !== nothing && b !== nothing && abs(a - b) <= tol * max(1.0, abs(b))
    println("Autoprueba de la comparación entre grupos")

    # Datos fijos (los mismos que en el prototipo)
    ax = [4.1, 5.3, 6.8, 7.2, 5.9, 8.4, 6.1]
    ay = [3.2, 4.4, 5.0, 3.9, 6.0, 4.7]
    bx = [3.0, 5.0, 5.0, 7.0, 8.0, 8.0, 9.0, 10.0]
    by = [2.0, 3.0, 4.0, 4.0, 5.0, 6.0, 6.0, 7.0, 9.0]
    gc = [[2.1, 3.4, 2.9, 3.8, 2.5], [4.0, 5.5, 4.8, 6.9, 5.1, 4.4], [3.1, 9.0, 2.2, 7.7, 6.0, 1.0, 8.8]]

    # 1) Rangos y distribución exacta de U
    r, emp = cg_rangos([3.0, 1.0, 3.0, 2.0])
    ok &= chequear("rangos medios con empate: (3,1,3,2) → (3,5; 1; 3,5; 2) y un grupo de 2 empatados", r == [3.5, 1.0, 3.5, 2.0] && emp == [2])
    ok &= chequear("distribución exacta de U (4 vs 3): coeficientes del binomio de Gauss, suman C(7,3) = 35",
                   cg_dist_u(4, 3) == [1, 1, 2, 3, 4, 4, 5, 4, 4, 3, 2, 1, 1])
    ok &= chequear("p mínimo alcanzable: 3 vs 3 → 0,1 (y 3 vs 3 completamente separados da exactamente 0,1); 1 vs 1 → 1",
                   cerca(cg_p_minimo_posible(3, 3), 0.1) && cg_p_minimo_posible(1, 1) == 1.0 &&
                   cerca(cg_mann_whitney([10.0, 11.0, 12.0], [1.0, 2.0, 3.0])["p"], 0.1))

    # 2) Mann–Whitney: exacto (sin empates) y asintótico (con empates)
    mwa = cg_mann_whitney(ax, ay)
    ok &= chequear("Mann–Whitney sin empates (7 vs 6): método exacto, U = 36, p = 0,034965", mwa["metodo"] == "exacto" &&
                   cerca(mwa["estadistico"], 36.0) && cerca(mwa["p"], 0.03496503496503496, 1e-12))
    mwb = cg_mann_whitney(bx, by)
    ok &= chequear("Mann–Whitney con empates (8 vs 9): normal con corrección, U = 51,5, p = 0,146418", mwb["metodo"] == "asintótico" &&
                   cerca(mwb["estadistico"], 51.5) && cerca(mwb["p"], 0.14641764758752174, 1e-9))

    # 3) Welch y tamaños de efecto
    wa = cg_welch_t(ax, ay)
    ok &= chequear("t de Welch (A): t = 2,638459, gl = 10,606977, p = 0,023698",
                   cerca(wa["estadistico"], 2.638458735289841) && cerca(wa["gl"], 10.606976707023307) && cerca(wa["p"], 0.023697712367334315))
    wb = cg_welch_t(bx, by)
    ok &= chequear("t de Welch (B): t = 1,605832, gl = 14,320243, p = 0,130131",
                   cerca(wb["estadistico"], 1.6058315376324104) && cerca(wb["gl"], 14.320243896613473) && cerca(wb["p"], 0.13013097295094805))
    efa = cg_efecto_rangos(ax, ay)
    ok &= chequear("A: AUC = 6/7 = 0,857143, IC DeLong [0,499029; 0,973075]; δ de Cliff = 0,714286, IC [−0,001942; 0,946150]",
                   cerca(efa["auc"], 0.8571428571428571) && cerca(efa["auc_ic"][1], 0.4990289938152064) && cerca(efa["auc_ic"][2], 0.9730749222044371) &&
                   cerca(efa["cliff_delta"], 0.7142857142857142) && cerca(efa["cliff_ic"][1], -0.0019420123695872427) && cerca(efa["cliff_ic"][2], 0.9461498444088743))
    efb = cg_efecto_rangos(bx, by)
    ok &= chequear("B (con empates): AUC = 0,715278, IC [0,411174; 0,900378]; δ = 0,430556",
                   cerca(efb["auc"], 0.7152777777777778) && cerca(efb["auc_ic"][1], 0.4111744012563826) && cerca(efb["auc_ic"][2], 0.9003775314000096) &&
                   cerca(efb["cliff_delta"], 0.4305555555555556))
    ha = cg_hedges_g(ax, ay)
    hb = cg_hedges_g(bx, by)
    ok &= chequear("g de Hedges: A = 1,325845 [0,122207; 2,529483]; B = 0,744941 [−0,239798; 1,729680]",
                   cerca(ha["hedges_g"], 1.3258448487334238) && cerca(ha["hedges_ic"][1], 0.12220674974337498) && cerca(ha["hedges_ic"][2], 2.529482947723473) &&
                   cerca(hb["hedges_g"], 0.7449407642761393) && cerca(hb["hedges_ic"][1], -0.23979784539137217) && cerca(hb["hedges_ic"][2], 1.7296793739436507))
    ok &= chequear("separación completa (AUC = 0): el IC no es estimable (nothing), no un error",
                   cg_auc_delong([1.0, 2.0, 3.0, 4.0], [10.0, 11.0, 12.0])[2] === nothing)
    ok &= chequear("varianza cero en ambos grupos: Welch y Hedges no estimables (nothing)",
                   cg_welch_t([2.0, 2.0, 2.0], [3.0, 3.0]) === nothing && cg_hedges_g([2.0, 2.0, 2.0], [3.0, 3.0]) === nothing)

    # 4) Más de dos grupos
    kw, eps2 = cg_kruskal_wallis(gc)
    aw = cg_anova_welch(gc)
    ok &= chequear("Kruskal–Wallis (3 grupos): H = 4,594319, p = 0,100544, ε² = 0,270254",
                   cerca(kw["estadistico"], 4.594319131161235) && cerca(kw["p"], 0.10054402722413801) && cerca(eps2, 0.27025406653889616))
    ok &= chequear("ANOVA de Welch (3 grupos): F = 9,182916, gl = (2; 9,610060), p = 0,005891",
                   cerca(aw["estadistico"], 9.182915655729932) && aw["gl"][1] == 2 && cerca(aw["gl"][2], 9.61006013508069) && cerca(aw["p"], 0.005890988559007861))
    ok &= chequear("η² = SC_entre/SC_total = 0,215884", cerca(cg_eta_cuadrado(gc), 0.21588404466141428))
    w2 = cg_anova_welch([ax, ay])
    ok &= chequear("ANOVA de Welch con k = 2: F = t², mismo p y mismos gl que Welch",
                   cerca(w2["estadistico"], wa["estadistico"]^2) && cerca(w2["p"], wa["p"]) && cerca(w2["gl"][2], wa["gl"]) && w2["gl"][1] == 1)
    ok &= chequear("ANOVA de Welch con un grupo de varianza 0: no estimable", cg_anova_welch([[1.0, 1.0, 1.0], [2.0, 3.0, 5.0], [1.0, 2.0, 8.0]]) === nothing)

    # 5) Comparaciones múltiples
    ps = [0.001, 0.008, 0.039, 0.041, 0.042, 0.06, 0.074, 0.205, 0.212, 0.216]
    bh_esp = [0.01, 0.04, 0.084, 0.084, 0.084, 0.1, 0.1057142857142857, 0.216, 0.216, 0.216]
    holm_esp = [0.01, 0.072, 0.312, 0.312, 0.312, 0.312, 0.312, 0.615, 0.615, 0.615]
    ok &= chequear("Benjamini–Hochberg (10 p-valores) = scipy.false_discovery_control", all(cerca.(cg_benjamini_hochberg(ps), bh_esp, 1e-12)))
    ok &= chequear("Holm (10 p-valores) = máx_{j≤i}(m−j+1)·p₍ⱼ₎", all(cerca.(cg_holm(ps), holm_esp, 1e-12)))
    desorden = [0.041, 0.001, 0.216, 0.008]
    ok &= chequear("BH y Holm devuelven los valores en el ORDEN ORIGINAL (no ordenados)",
                   all(cerca.(cg_benjamini_hochberg(desorden), [0.0546666666666667, 0.004, 0.216, 0.016], 1e-9)) &&
                   all(cerca.(cg_holm(desorden), [0.082, 0.004, 0.216, 0.024], 1e-9)))

    # 6) `comparar_grupos` de punta a punta (2 grupos, faltantes, constante, n < 2, todo vacío)
    sujetos = _cg_sujetos_de_prueba()
    R = comparar_grupos(sujetos, ["Sanos", "Enfermos"], "no_parametrica", 0.05)
    res = R["resultados"]
    por = Dict{String,Any}(f["clave"] => f for f in res)
    ok &= chequear("orden de la tabla: por q ascendente, luego sin variación, luego omitidas",
                   [f["clave"] for f in res] == ["f_a", "f_b", "f_const", "f_corta", "f_nula"])
    ok &= chequear("resumen: familia m = 2 (la constante y las omitidas no cuentan), n por grupo, referencia = primer grupo",
                   R["resumen"]["m"] == 2 && R["resumen"]["n_sujetos"] == Dict{String,Any}("Sanos" => 9, "Enfermos" => 8) && R["resumen"]["referencia"] == "Sanos")
    fa = por["f_a"]
    ok &= chequear("f_a: faltantes descartados (n = 6 y 7), p de Mann–Whitney exacto, q = 2p (m = 2), Holm = 2p",
                   fa["n"] == Dict{String,Any}("Sanos" => 6, "Enfermos" => 7) && cerca(fa["p"], 0.03496503496503497, 1e-12) &&
                   cerca(fa["q_bh"], 0.06993006993006994, 1e-12) && cerca(fa["p_holm"], 0.06993006993006994, 1e-12) && fa["prueba_principal"]["metodo"] == "exacto")
    ok &= chequear("f_a con α = 0,05 NO es significativa (q = 0,0699) y el grupo mayor es Enfermos", fa["significativa"] == false && fa["mayor_en"] == "Enfermos")
    ok &= chequear("f_a: orientación — AUC > 0,5 y g > 0 porque Enfermos (comparado) tiende a valores mayores que Sanos (referencia)",
                   fa["efecto"]["auc"] > 0.5 && fa["efecto"]["hedges_g"] > 0 && fa["efecto"]["cliff_delta"] > 0)
    fb = por["f_b"]
    ok &= chequear("f_b (empates): p asintótico 0,146418 y q = p (rango 2 de 2)", cerca(fb["p"], 0.14641764758752174, 1e-9) && cerca(fb["q_bh"], fb["p"]) && fb["prueba_principal"]["metodo"] == "asintótico")
    ok &= chequear("la otra prueba (Welch) también se informa: t = 2,638459 en f_a", cerca(fa["otra_prueba"]["estadistico"], 2.638458735289841) && fa["otra_prueba"]["nombre"] == "t de Welch")
    ok &= chequear("f_const: sin variación → estado, p = 1 y no entra en la familia",
                   por["f_const"]["estado"] == "sin_variacion" && por["f_const"]["p"] == 1.0 && por["f_const"]["significativa"] == false)
    ok &= chequear("f_corta (un solo valor en Enfermos) y f_nula (todo vacío): omitidas con el motivo",
                   por["f_corta"]["estado"] == "omitida" && occursin("Enfermos", por["f_corta"]["nota"]) &&
                   por["f_nula"]["estado"] == "omitida" && por["f_nula"]["p"] === nothing)
    R10 = comparar_grupos(sujetos, ["Sanos", "Enfermos"], "no_parametrica", 0.10)
    ok &= chequear("con α = 0,10: f_a pasa a significativa (q = 0,0699 ≤ 0,10) y f_b no; el resumen cuenta 1",
                   R10["resultados"][1]["significativa"] == true && R10["resultados"][2]["significativa"] == false && R10["resumen"]["n_significativas"] == 1)
    RP = comparar_grupos(sujetos, ["Sanos", "Enfermos"], "parametrica", 0.05)
    fap = RP["resultados"][1]
    ok &= chequear("prueba principal paramétrica: la principal es Welch (p = 0,023698) y la otra Mann–Whitney",
                   fap["clave"] == "f_a" && fap["prueba_principal"]["nombre"] == "t de Welch" && cerca(fap["p"], 0.023697712367334315) && fap["otra_prueba"]["nombre"] == "Mann–Whitney U")
    ok &= chequear("p mínimo alcanzable de f_a (7 vs 6) = 2/C(13,6) = 0,001166", cerca(fa["p_min_posible"], 0.0011655011655011655))

    # 7) Tres grupos: Kruskal–Wallis, post-hoc por pares con Holm, orientación por pares
    s3 = Dict{String,Any}[]
    for (g, vs) in zip(["G1", "G2", "G3"], gc)
        for (i, v) in enumerate(vs)
            push!(s3, Dict{String,Any}("archivo" => "$(g)_$(i)", "grupo" => g, "caracteristicas" => Dict{String,Any}("f" => v)))
        end
    end
    R3 = comparar_grupos(s3, ["G1", "G2", "G3"], "no_parametrica", 0.05)
    f3 = R3["resultados"][1]
    ok &= chequear("3 grupos: principal = Kruskal–Wallis (p = 0,100544), efecto ε² y η², mayor rango medio en G2",
                   f3["prueba_principal"]["nombre"] == "Kruskal–Wallis H" && cerca(f3["p"], 0.10054402722413801) &&
                   cerca(f3["efecto"]["epsilon2"], 0.27025406653889616) && cerca(f3["efecto"]["eta2"], 0.21588404466141428) && f3["mayor_en"] == "G2" &&
                   f3["otra_prueba"]["nombre"] == "ANOVA de Welch F" && f3["p_min_posible"] === nothing)
    pares = f3["pares"]
    ok &= chequear("post-hoc: 3 pares (G1–G2, G1–G3, G2–G3) con U = 30, 24, 23 y p exactos 0,004329 / 0,343434 / 0,835664",
                   length(pares) == 3 && [(p["a"], p["b"]) for p in pares] == [("G1", "G2"), ("G1", "G3"), ("G2", "G3")] &&
                   cerca(pares[1]["u"], 30.0) && cerca(pares[2]["u"], 24.0) && cerca(pares[3]["u"], 23.0) &&
                   cerca(pares[1]["p"], 0.004329004329004329) && cerca(pares[2]["p"], 0.3434343434343434) && cerca(pares[3]["p"], 0.8356643356643356))
    ok &= chequear("post-hoc: Holm dentro de la característica (0,012987 / 0,686869 / 0,835664) y orientación (AUC del segundo frente al primero)",
                   cerca(pares[1]["p_holm"], 0.012987012987012988) && cerca(pares[2]["p_holm"], 0.6868686868686869) && cerca(pares[3]["p_holm"], 0.8356643356643356) &&
                   cerca(pares[1]["auc"], 1.0) && pares[1]["mayor_en"] == "G2" && pares[1]["auc_ic"] === nothing && cerca(pares[3]["auc"], 0.5476190476190477))
    R3p = comparar_grupos(s3, ["G1", "G2", "G3"], "parametrica", 0.05)
    ok &= chequear("3 grupos con principal paramétrica: ANOVA de Welch (p = 0,005891) y q = p; significativa a α = 0,05",
                   R3p["resultados"][1]["prueba_principal"]["nombre"] == "ANOVA de Welch F" && cerca(R3p["resultados"][1]["p"], 0.005890988559007861) &&
                   R3p["resultados"][1]["significativa"] == true)

    # 8) Entrada tal como llega del navegador (JSON3.read) y salida serializable
    desde_json = comparar_grupos(JSON3.read(JSON3.write(sujetos)), ["Sanos", "Enfermos"], "no_parametrica", 0.05)
    ok &= chequear("entrada leída con JSON3 (claves Symbol, null) da el mismo resultado", cerca(desde_json["resultados"][1]["p"], fa["p"], 1e-12) && desde_json["resumen"]["m"] == 2)
    texto = JSON3.write(R3)
    ok &= chequear("la salida se serializa a JSON sin error (NaN/Inf ya convertidos a null)", occursin("Kruskal", texto) && !occursin("NaN", texto) && !occursin("Infinity", texto))

    # 9) Validaciones
    falla(f) = try
        f()
        false
    catch
        true
    end
    ok &= chequear("un solo grupo, grupos repetidos, prueba inválida o α fuera de (0,1): error",
                   falla(() -> comparar_grupos(sujetos, ["Sanos"], "no_parametrica", 0.05)) &&
                   falla(() -> comparar_grupos(sujetos, ["Sanos", "Sanos"], "no_parametrica", 0.05)) &&
                   falla(() -> comparar_grupos(sujetos, ["Sanos", "Enfermos"], "otra", 0.05)) &&
                   falla(() -> comparar_grupos(sujetos, ["Sanos", "Enfermos"], "parametrica", 1.5)))
    ok &= chequear("un grupo sin sujetos: error", falla(() -> comparar_grupos(sujetos, ["Sanos", "Fantasma"], "no_parametrica", 0.05)))
    duplicados = vcat(sujetos, [Dict{String,Any}("archivo" => "s1.nii", "grupo" => "Sanos", "caracteristicas" => Dict{String,Any}("f_a" => 1.0))])
    ok &= chequear("el mismo archivo dos veces en un grupo: error (pseudorreplicación)", falla(() -> comparar_grupos(duplicados, ["Sanos", "Enfermos"], "no_parametrica", 0.05)))
    mismo_nombre = Dict{String,Any}[Dict{String,Any}("archivo" => "p1.nii", "grupo" => g, "caracteristicas" => Dict{String,Any}("f" => v)) for (g, v) in
                   [("A", 1.0), ("A", 2.0), ("A", 3.0), ("B", 4.0), ("B", 5.0), ("B", 7.0)]]
    mismo_nombre[2]["archivo"] = "p2.nii"; mismo_nombre[3]["archivo"] = "p3.nii"; mismo_nombre[5]["archivo"] = "p2.nii"; mismo_nombre[6]["archivo"] = "p3.nii"
    ok &= chequear("el mismo nombre de archivo en grupos distintos es válido (el sujeto es grupo + archivo)", !falla(() -> comparar_grupos(mismo_nombre, ["A", "B"], "no_parametrica", 0.05)))

    println(ok ? "✅ Autoprueba de la comparación: todo en orden" : "❌ Autoprueba de la comparación: HAY FALLOS")
    return ok
end
