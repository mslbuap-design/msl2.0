if Threads.nthreads() == 1
    println("⚠️  Julia se inició con 1 solo thread   ⚠️")
    println("   Para habilitar paralelismo en analisis radiomico, reinicia Julia con:")
    println("   julia -t auto server.jl")
    println("   (o especifica número: julia -t 4 server.jl)")
    println("")
end

using HTTP
using JSON3
using Dates

# ==============================================================================
# INFRAESTRUCTURA (src/) — se carga antes que la lógica de dominio porque
# esta última (ProcesamientoImagenes.jl, AnalisisRadiomico.jl,
# AnalisisEstadistico.jl) y los handlers dependen de estos nombres estando
# ya en scope (TEMP_DIR, json_response, registrar_ruta!, etc.)
# ==============================================================================

include(joinpath("src", "http_utils.jl"));   using .HttpUtils
include(joinpath("src", "file_resolver.jl")); using .FileResolver
include(joinpath("src", "image_cache.jl"));  using .ImagenesCache
include(joinpath("src", "jobs.jl"));          using .Jobs
include(joinpath("src", "router.jl"));        using .Router
include(joinpath("src", "directory_scan.jl"))

include(joinpath("database", "db.jl"));      using .Database
include(joinpath("database", "schema.jl"));  using .Schema
include(joinpath("database", "queries.jl")); using .Queries

# IMPORTANTE: Intentar cargar NativeFileDialog (opcional)
NATIVE_FILE_DIALOG_AVAILABLE = false
try
    using NativeFileDialog
    global NATIVE_FILE_DIALOG_AVAILABLE = true
    println("✅ NativeFileDialog.jl cargado - Selector de carpetas disponible")
catch e
    println("⚠️  NativeFileDialog.jl no disponible - Solo modo navegador")
    println("   Instalar con: using Pkg; Pkg.add(\"NativeFileDialog\")")
end

# Módulos de dominio (procesamiento de imágenes, radiómica, estadística)
include("ProcesamientoImagenes.jl")
include("AnalisisRadiomico.jl")
include("AnalisisEstadistico.jl")

# ==============================================================================
# CONFIGURACIÓN GLOBAL
# ==============================================================================
#
# Lo que queda de estado global es, a propósito, sólo configuración de
# servidor (puerto, carpeta base de proyectos, conexión a BD) — nada que
# dependa de "cuál es el proyecto/archivo con el que está trabajando el
# usuario ahora mismo" (eso era `PROYECTO_ACTUAL`/`LOADED_IMAGES` en la
# versión anterior, y era lo que causaba que dos investigadores con
# proyectos distintos abiertos a la vez se pisaran entre sí).

const PORT = parse(Int, get(ENV, "MSL_PORT", "8000"))

# Antes hardcodeado a "/root/projects" ignorando esta misma variable que
# docker-compose.yml ya define (MSL_PROJECTS_DIR) — ahora sí se respeta.
const PROJECTS_DIR = get(ENV, "MSL_PROJECTS_DIR", "/root/projects")

# Modo de operación (julia o python - preparación futura). Es un toggle de
# servidor completo (no por-proyecto ni por-usuario), así que sigue siendo
# un `Ref` global sin problema — no es la misma clase de bug que
# `PROYECTO_ACTUAL`.
const MODO_OPERACION = Ref("julia")

# Conexión PostgreSQL
const DB_CONN = Database.connect_db()
Schema.crear_tablas(DB_CONN)

# Inicializar directorio temporal (fallback para archivos subidos desde el
# navegador — ver FileResolver)
init_temp_dir()

# ==============================================================================
# HANDLERS — cada archivo se auto-registra en el Router al incluirse.
# ==============================================================================

include(joinpath("src", "handlers", "sistema.jl"))
include(joinpath("src", "handlers", "proyectos.jl"))
include(joinpath("src", "handlers", "archivos.jl"))
include(joinpath("src", "handlers", "visualizacion.jl"))
include(joinpath("src", "handlers", "radiomica.jl"))
include(joinpath("src", "handlers", "estadistica.jl"))

# ==============================================================================
# ROUTER PRINCIPAL
# ==============================================================================

function handle_request(req::HTTP.Request)
    # CORS preflight
    if req.method == "OPTIONS"
        return add_cors_headers(HTTP.Response(200, ""))
    end

    try
        respuesta = Router.despachar(req)

        if isnothing(respuesta)
            uri = HTTP.URI(req.target)
            return error_response(404, "Ruta no encontrada"; extra=Dict("path" => uri.path))
        end

        return respuesta
    catch e
        println("❌ Error interno: ", e)
        println(stacktrace(catch_backtrace()))
        return error_response(500, "Error interno del servidor"; extra=Dict("message" => string(e)))
    end
end

# ==============================================================================
# INICIAR SERVIDOR
# ==============================================================================

println("╔═══════════════════════════════════════════════════════════╗")
println("        MSL Process Backend v3.0 - Router + Jobs asíncronos")
println("╠═══════════════════════════════════════════════════════════╣")
println("    Puerto: http://localhost:$PORT")
println("    Proyectos: $PROJECTS_DIR")
println("    Temp: $TEMP_DIR")
println("    NativeFileDialog: $(NATIVE_FILE_DIALOG_AVAILABLE ? "✅ Disponible" : "❌ No disponible")")
println("    Modo: $(MODO_OPERACION[])")
println("    Threads: $(Threads.nthreads())")
println("    Rutas registradas: $(length(Router.RUTAS))")
println("╚═══════════════════════════════════════════════════════════╝")
println("Presiona Ctrl+C para detener\n")

# ==============================================================================
# CONFIGURACIÓN DE RED
# ==============================================================================

const SERVER_MODE = get(ENV, "MSL_SERVER_MODE", "desktop")
const HOST = SERVER_MODE == "server" ? "0.0.0.0" : "127.0.0.1"

if SERVER_MODE == "server"
    println("🌐 MODO SERVIDOR - Escuchando en toda la red (0.0.0.0:$PORT)")
    println("   Acceso desde otras PCs: http://[IP-DEL-SERVIDOR]:$PORT")
    println("   ⚠️  Asegúrate de configurar el firewall correctamente")
else
    println("🖥️  MODO ESCRITORIO - Solo local (127.0.0.1:$PORT)")
end

HTTP.serve(handle_request, HOST, PORT)
