# ==============================================================================
# GrafosCache
# ==============================================================================
#
# Guarda en memoria, por cada archivo analizado en el módulo de grafos, lo
# necesario para dibujar cortes de validación sin volver a correr el análisis:
# el volumen analizado, la máscara vascular, el esqueleto y los nodos. Así el
# visor del frontend puede pedir cualquier corte (`POST /api/grafos/corte`) con
# solo un `resultado_id`.
#
# Mismo criterio que `ImagenesCache`: acceso protegido con `ReentrantLock`
# (el análisis corre en una tarea propia y HTTP.jl atiende requests
# concurrentes). A diferencia de aquel, acá hay un PRESUPUESTO de memoria:
# los volúmenes pueden ser grandes y se acumulan un resultado por archivo
# analizado, así que cuando se supera el presupuesto se descartan los
# resultados menos recientemente usados (siempre se conserva el último).
# Un resultado descartado hace que el visor muestre "no disponible"; basta
# con volver a ejecutar el análisis de ese archivo.
# ==============================================================================

module GrafosCache

export registrar!, obtener, limpiar_grafos!, num_resultados_cacheados

# ~1,5 GB para todos los resultados guardados (volumen + máscara + esqueleto).
const _PRESUPUESTO_BYTES = 1_500_000_000

const _LOCK = ReentrantLock()
const _DATOS = Dict{String,Any}()
const _BYTES = Dict{String,Int}()
const _ORDEN = String[]            # del menos al más recientemente usado
const _CONTADOR = Ref(0)

_estimar_bytes(datos) = sizeof(datos.volumen) + sizeof(datos.mascara) + sizeof(datos.esqueleto)

"""
Guarda `datos` (NamedTuple con `volumen`, `mascara`, `esqueleto`, `nodos`,
`voxel_dims`, `vmin`, `vmax`) y devuelve su `resultado_id`.
"""
function registrar!(datos)
    return lock(_LOCK) do
        _CONTADOR[] += 1
        id = "g" * string(_CONTADOR[], base=36) * "-" * string(time_ns() % 1_000_000, base=36)
        _DATOS[id] = datos
        _BYTES[id] = _estimar_bytes(datos)
        push!(_ORDEN, id)

        total = sum(values(_BYTES))
        while total > _PRESUPUESTO_BYTES && length(_ORDEN) > 1
            viejo = popfirst!(_ORDEN)
            total -= _BYTES[viejo]
            delete!(_DATOS, viejo)
            delete!(_BYTES, viejo)
        end
        id
    end
end

"""Devuelve los datos de `id` (y lo marca como recientemente usado), o `nothing`."""
function obtener(id::AbstractString)
    return lock(_LOCK) do
        d = get(_DATOS, String(id), nothing)
        if d !== nothing
            filter!(x -> x != String(id), _ORDEN)
            push!(_ORDEN, String(id))
        end
        d
    end
end

function limpiar_grafos!()
    lock(_LOCK) do
        empty!(_DATOS)
        empty!(_BYTES)
        empty!(_ORDEN)
    end
    return nothing
end

function num_resultados_cacheados()
    return lock(_LOCK) do
        length(_DATOS)
    end
end

end # module
