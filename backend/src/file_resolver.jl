# ==============================================================================
# FileResolver
# ==============================================================================
#
# Antes: `load-image`, `get-slice` y `analisis-radiomico` ubicaban TODO por
# `joinpath(TEMP_DIR, filename)`. Como TEMP_DIR es un único directorio plano
# compartido por todo el servidor, dos proyectos con un archivo del mismo
# nombre (p.ej. "T1.nii") se pisaban entre sí, tanto en disco como en el
# caché en memoria (`LOADED_IMAGES`).
#
# Ahora: el frontend manda la ruta ABSOLUTA del archivo cuando la conoce
# (`fullPath` en el árbol que ya devuelve `escanear_directorio_recursivo`,
# el cual vive dentro del volumen montado de Docker `./projects`). Si ya es
# una ruta absoluta existente, se usa tal cual — sin pasar por TEMP_DIR ni
# por ninguna subida en Base64. TEMP_DIR queda como fallback exclusivamente
# para archivos que de verdad solo existen subidos desde el navegador
# (selector de carpeta sin equivalente en disco del backend).
#
# Como la ruta absoluta real ya es única por proyecto (dos proyectos nunca
# comparten ruta en disco), usarla como clave de caché en `ImagenesCache`
# resuelve la colisión de raíz sin necesitar rastrear "proyecto actual" en
# ningún estado global del servidor.
# ==============================================================================

module FileResolver

export TEMP_DIR, init_temp_dir, resolver_ruta_archivo, es_ruta_absoluta

# Directorio temporal — único uso: archivos que llegan por Base64 desde el
# navegador y no tienen contraparte en disco accesible por el backend.
const TEMP_DIR = joinpath(tempdir(), "msl_process_cache")

function init_temp_dir()
    if !isdir(TEMP_DIR)
        mkpath(TEMP_DIR)
        println("📁 Directorio temporal creado: $TEMP_DIR")
    end
    return TEMP_DIR
end

"""
Verifica si una ruta es absoluta, de forma multiplataforma (Windows y
Unix). Julia's `isabspath` ya hace esto correctamente desde 1.x, pero se
mantiene esta función con nombre explícito para dejar clara la intención
en el resto del código (y por si alguna vez hace falta un caso especial).
"""
es_ruta_absoluta(ruta::AbstractString) = isabspath(ruta)

"""
    resolver_ruta_archivo(archivo::AbstractString) -> Union{String, Nothing}

Resuelve la ruta real en disco de un archivo referenciado por el frontend.

Prioridad:
1. Si `archivo` ya es una ruta absoluta y existe -> se usa directo (este es
   el caso normal para archivos que viven dentro de un proyecto ya montado
   en `./projects`, vía `fullPath` del árbol).
2. Si no, se busca como nombre de archivo dentro de `TEMP_DIR` (compatibi-
   lidad con archivos subidos desde el navegador vía `/api/upload-file`).
3. Si tampoco está ahí, se busca recursivamente dentro de `TEMP_DIR` por si
   el nombre no es exactamente el que se subió (último recurso, igual que
   el comportamiento previo).

Devuelve `nothing` si no se pudo localizar el archivo en ningún lado.
"""
function resolver_ruta_archivo(archivo::AbstractString)
    archivo = String(archivo)

    if es_ruta_absoluta(archivo) && isfile(archivo)
        return archivo
    end

    candidata_temp = joinpath(TEMP_DIR, archivo)
    if isfile(candidata_temp)
        return candidata_temp
    end

    # Último recurso: buscar por nombre base en subcarpetas de TEMP_DIR.
    nombre_base = basename(archivo)
    if isdir(TEMP_DIR)
        for (root, _dirs, files) in walkdir(TEMP_DIR)
            if nombre_base in files
                return joinpath(root, nombre_base)
            end
        end
    end

    return nothing
end

end # module
