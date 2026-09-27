# ==============================================================================
# HttpUtils — helpers compartidos por todos los handlers
# ==============================================================================

module HttpUtils

using HTTP
using JSON3

export add_cors_headers, json_response, error_response, leer_body_json,
       parse_int_seguro

"""
Agrega headers CORS a la respuesta. Se sigue permitiendo PUT (nuevos
endpoints de renombrar) además de los métodos ya soportados.
"""
function add_cors_headers(response::HTTP.Response)
    HTTP.setheader(response, "Access-Control-Allow-Origin" => "*")
    HTTP.setheader(response, "Access-Control-Allow-Methods" => "GET, POST, PUT, DELETE, OPTIONS")
    HTTP.setheader(response, "Access-Control-Allow-Headers" => "Content-Type")
    HTTP.setheader(response, "Content-Type" => "application/json")
    return response
end

"""
Construye una respuesta JSON con headers CORS ya aplicados. Es el único
punto de salida que deberían usar los handlers — así ningún endpoint nuevo
puede "olvidarse" de los headers CORS como pasaba antes al copiar/pegar
bloques `elseif`.
"""
function json_response(status::Integer, data)
    return add_cors_headers(HTTP.Response(status, JSON3.write(data)))
end

"""
Atajo para respuestas de error: siempre `Dict("success" => false, "error" => ...)`.
"""
function error_response(status::Integer, mensaje::AbstractString; extra::Dict=Dict())
    data = merge(Dict("success" => false, "error" => String(mensaje)), extra)
    return json_response(status, data)
end

"""
Lee y parsea el body JSON de un request. Devuelve un `JSON3.Object` vacío
si el body está vacío (evita que cada handler repita el mismo try/catch).
"""
function leer_body_json(req::HTTP.Request)
    body = String(req.body)
    if isempty(strip(body))
        return JSON3.read("{}")
    end
    return JSON3.read(body)
end

"""
Convierte un string a Int de forma segura. Devuelve `nothing` si no se
puede parsear (en vez de lanzar excepción) — usado para parámetros de ruta
como `/api/proyecto/:id`.
"""
function parse_int_seguro(s::AbstractString)
    try
        return parse(Int, s)
    catch
        return nothing
    end
end

end # module
