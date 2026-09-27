# ==============================================================================
# Jobs — patrón asíncrono para análisis largos
# ==============================================================================
#
# Antes, `analisis-radiomico` y `analisis-estadistico` corrían de forma
# síncrona dentro del propio request HTTP: con datasets grandes, eso
# bloqueaba esa tarea de principio a fin, sin reportar avance y sin que el
# handler pudiera hacer nada más mientras tanto.
#
# Ahora cada análisis se ejecuta en una tarea propia vía `Threads.@spawn`,
# registrada acá con un `job_id`. El handler HTTP tiene dos formas de
# consumir eso:
#
#   - Modo síncrono (comportamiento por defecto, compatible con el
#     frontend actual): el handler espera (`esperar_job`) a que el job
#     termine y responde con el resultado completo, igual que antes. La
#     diferencia real es que la espera se hace con `wait` sobre un
#     `Base.Event` — eso SÍ cede el control al scheduler, así que otras
#     requests concurrentes (otro usuario abriendo su propio proyecto, por
#     ejemplo) no quedan detrás en la cola.
#   - Modo asíncrono explícito (`"async" => true` en el body): el handler
#     responde de inmediato con `job_id` y el cliente consulta progreso con
#     `GET /api/jobs/:id`. El frontend actual no usa esto todavía, pero el
#     endpoint ya queda disponible para cuando se quiera agregar una barra
#     de progreso real en la interfaz.
# ==============================================================================

module Jobs

using Base.Threads
using Dates

export Job, crear_job!, obtener_job, actualizar_progreso!, completar_job!,
       fallar_job!, esperar_job, lanzar_job!, job_a_dict

mutable struct Job
    id::String
    tipo::String
    estado::String        # "corriendo" | "completado" | "error"
    progreso::Float64      # 0.0 - 1.0
    mensaje::String
    resultado::Any
    error::String
    creado_en::String
    evento::Base.Event
end

const _JOBS = Dict{String, Job}()
const _LOCK = ReentrantLock()
const _CONTADOR = Threads.Atomic{Int}(0)

function _generar_id(tipo::AbstractString)
    n = Threads.atomic_add!(_CONTADOR, 1)
    return "$(tipo)_$(n)_$(round(Int, time() * 1000))"
end

"""
Crea y registra un job nuevo en estado "corriendo". Devuelve el `Job`.
"""
function crear_job!(tipo::AbstractString)
    job = Job(
        _generar_id(tipo),
        String(tipo),
        "corriendo",
        0.0,
        "Iniciando...",
        nothing,
        "",
        string(Dates.now()),
        Base.Event(),
    )
    lock(_LOCK) do
        _JOBS[job.id] = job
    end
    return job
end

function obtener_job(id::AbstractString)
    lock(_LOCK) do
        return get(_JOBS, id, nothing)
    end
end

function actualizar_progreso!(job::Job, progreso::Real, mensaje::AbstractString="")
    job.progreso = clamp(Float64(progreso), 0.0, 1.0)
    if !isempty(mensaje)
        job.mensaje = String(mensaje)
    end
    return nothing
end

function completar_job!(job::Job, resultado)
    job.resultado = resultado
    job.progreso = 1.0
    job.estado = "completado"
    job.mensaje = "Completado"
    notify(job.evento)
    return nothing
end

function fallar_job!(job::Job, error_msg::AbstractString)
    job.estado = "error"
    job.error = String(error_msg)
    job.mensaje = "Error"
    notify(job.evento)
    return nothing
end

"""
    lanzar_job!(tipo, fn) -> Job

Crea un job y lanza `fn(job)` en una tarea de `Threads.@spawn`. `fn` es
responsable de llamar a `completar_job!`/`fallar_job!` al terminar (y,
opcionalmente, a `actualizar_progreso!` mientras corre).
"""
function lanzar_job!(tipo::AbstractString, fn::Function)
    job = crear_job!(tipo)
    Threads.@spawn begin
        try
            fn(job)
        catch e
            fallar_job!(job, sprint(showerror, e))
        end
    end
    return job
end

"""
    esperar_job(job; timeout_s=nothing)

Espera (cediendo el scheduler, no ocupando CPU) a que el job termine. Si se
da `timeout_s`, deja de esperar después de ese tiempo aunque el job siga
corriendo (el resultado se puede consultar después vía `GET /api/jobs/:id`).
"""
function esperar_job(job::Job; timeout_s::Union{Nothing,Real}=nothing)
    if isnothing(timeout_s)
        wait(job.evento)
    else
        Threads.@spawn begin
            sleep(timeout_s)
            notify(job.evento)
        end
        wait(job.evento)
    end
    return job
end

function job_a_dict(job::Job)
    return Dict(
        "job_id" => job.id,
        "tipo" => job.tipo,
        "estado" => job.estado,
        "progreso" => job.progreso,
        "mensaje" => job.mensaje,
        "error" => job.error,
        "creado_en" => job.creado_en,
    )
end

end # module
