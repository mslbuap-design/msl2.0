# ==============================================================================
# Escaneo de estructura de proyectos — funciones puras, sin estado global.
# (Extraídas tal cual del server.jl original; sólo cambiaron de archivo.)
# ==============================================================================

"""
Escanea un directorio recursivamente y retorna estructura JSON jerárquica.
"""
function escanear_directorio_recursivo(ruta::String, ruta_base::String="", nivel::Int=0)
    if isempty(ruta_base)
        ruta_base = ruta
    end

    nombre = basename(ruta)
    ruta_relativa = replace(ruta, ruta_base * (Sys.iswindows() ? "\\" : "/") => "")
    if isempty(ruta_relativa)
        ruta_relativa = nombre
    end

    # Archivo
    if isfile(ruta)
        return Dict(
            "name" => nombre,
            "type" => "file",
            "path" => ruta_relativa,
            "fullPath" => ruta,
            "compatible" => is_compatible_file(nombre)
        )
    end

    # Directorio
    children = []

    try
        items = readdir(ruta, join=true, sort=true)

        for item in items
            item_name = basename(item)

            # Ignorar carpetas especiales
            if startswith(item_name, "Resultados_") ||
               item_name in [".git", "node_modules", ".vscode", "__pycache__"]
                continue
            end

            child = escanear_directorio_recursivo(item, ruta_base, nivel + 1)
            push!(children, child)
        end
    catch e
        println("⚠️  Error escaneando $ruta: $e")
    end

    return Dict(
        "name" => nombre,
        "type" => "folder",
        "path" => ruta_relativa,
        "fullPath" => ruta,
        "children" => children
    )
end

"""
Cuenta archivos en estructura recursiva.
"""
function contar_archivos(estructura::Dict)
    if estructura["type"] == "file"
        return 1
    end

    count = 0
    if haskey(estructura, "children")
        for child in estructura["children"]
            count += contar_archivos(child)
        end
    end

    return count
end

"""
Cuenta carpetas en estructura recursiva.
"""
function contar_carpetas(estructura::Dict)
    if estructura["type"] == "file"
        return 0
    end

    count = 1  # Contar esta carpeta
    if haskey(estructura, "children")
        for child in estructura["children"]
            if child["type"] == "folder"
                count += contar_carpetas(child)
            end
        end
    end

    return count
end
