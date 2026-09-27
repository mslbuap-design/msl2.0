# ==============================================================================
# ImagenesCache
# ==============================================================================
#
# Reemplaza el `LOADED_IMAGES::Dict{String,Any}` global de la versión
# anterior. Dos cambios de fondo:
#
#   1. La clave ahora es la ruta ABSOLUTA resuelta del archivo (ver
#      `FileResolver.resolver_ruta_archivo`), no el nombre pelado. Como la
#      ruta absoluta es única por proyecto, dos proyectos con un archivo de
#      igual nombre (p.ej. "T1.nii") ya no se pisan en el caché.
#   2. El acceso está protegido con un `ReentrantLock`. Antes no hacía
#      falta porque no había nada asíncrono; ahora que `analisis-radiomico`
#      y `analisis-estadistico` corren en tareas propias (`Threads.@spawn`),
#      y que HTTP.jl puede atender requests concurrentes, un `Dict` sin
#      lock es una condición de carrera real.
# ==============================================================================

module ImagenesCache

export cachear_imagen!, obtener_imagen, limpiar_imagenes!, num_imagenes_cacheadas

const _CACHE = Dict{String, Any}()
const _LOCK = ReentrantLock()

function cachear_imagen!(ruta::AbstractString, datos)
    lock(_LOCK) do
        _CACHE[String(ruta)] = datos
    end
    return nothing
end

"""
Devuelve los datos cacheados para `ruta`, o `nothing` si no está cargada.
"""
function obtener_imagen(ruta::AbstractString)
    lock(_LOCK) do
        return get(_CACHE, String(ruta), nothing)
    end
end

function limpiar_imagenes!()
    lock(_LOCK) do
        empty!(_CACHE)
    end
    return nothing
end

function num_imagenes_cacheadas()
    lock(_LOCK) do
        return length(_CACHE)
    end
end

end # module
