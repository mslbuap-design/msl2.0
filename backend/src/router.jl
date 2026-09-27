# ==============================================================================
# Router — tabla de rutas en vez de la cadena de `elseif` original
# ==============================================================================
#
# El server.jl anterior tenía ~900 líneas de:
#
#   if path == "/api/x" && req.method == "GET"
#       ...
#   elseif path == "/api/y" && req.method == "POST"
#       ...
#   elseif startswith(path, "/api/proyecto/") && req.method == "GET"
#       ...
#   end
#
# Cada endpoint nuevo significaba insertarse a mano en esa cadena, sin
# aislamiento: un `return` olvidado o una variable mal nombrada en un bloque
# podía filtrarse al de al lado. Acá cada endpoint es una función normal
# (ver `src/handlers/*.jl`), registrada una sola vez en una tabla. Agregar
# un endpoint nuevo es agregar una línea a `registrar_rutas!`, no editar un
# árbol de `elseif` cada vez más profundo.
#
# También soporta parámetros de ruta (`/api/proyecto/:id/renombrar`), cosa
# que la versión anterior resolvía a mano con `split(path, "/")[end]` sólo
# para el caso más simple.
# ==============================================================================

module Router

using HTTP

export Ruta, registrar_ruta!, despachar, RUTAS

struct Ruta
    metodo::String
    segmentos::Vector{String}   # p.ej. ["api", "proyecto", ":id", "renombrar"]
    handler::Function            # (req::HTTP.Request, params::Dict{String,String}) -> HTTP.Response
end

const RUTAS = Ruta[]

_segmentos(path::AbstractString) = String.(filter(!isempty, split(path, '/')))

"""
    registrar_ruta!(metodo, patron, handler)

Registra un endpoint. `patron` usa `:nombre` para capturar segmentos, p.ej.
`"/api/proyecto/:id/renombrar"`.
"""
function registrar_ruta!(metodo::AbstractString, patron::AbstractString, handler::Function)
    push!(RUTAS, Ruta(uppercase(metodo), _segmentos(patron), handler))
    return nothing
end

function _coincide(ruta::Ruta, metodo::AbstractString, segs_path::Vector{<:AbstractString})
    ruta.metodo != uppercase(metodo) && return nothing
    length(ruta.segmentos) != length(segs_path) && return nothing

    params = Dict{String, String}()
    for (patron_seg, path_seg) in zip(ruta.segmentos, segs_path)
        if startswith(patron_seg, ":")
            params[patron_seg[2:end]] = String(path_seg)
        elseif patron_seg != path_seg
            return nothing
        end
    end
    return params
end

"""
Busca la primera ruta registrada que matchee método + path y ejecuta su
handler. Devuelve `nothing` si ninguna ruta matchea (el llamador decide qué
responder — típicamente un 404).
"""
function despachar(req::HTTP.Request)
    uri = HTTP.URI(req.target)
    segs_path = _segmentos(uri.path)

    for ruta in RUTAS
        params = _coincide(ruta, req.method, segs_path)
        if !isnothing(params)
            return ruta.handler(req, params)
        end
    end

    return nothing
end

end # module
