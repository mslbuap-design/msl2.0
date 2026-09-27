using NIfTI
using DICOM
using Images
using FileIO
using ImageIO
using Base64
using CodecZlib

# ══════════════════════════════════════════════════════════════════════
# CONFIGURACIÓN DE RUTAS
# ══════════════════════════════════════════════════════════════════════
#
# `TEMP_DIR` y `init_temp_dir()` ahora viven en `src/file_resolver.jl`
# (módulo `FileResolver`, cargado antes que este archivo en `server.jl`).
# Se mantienen accesibles acá sin cambiar el resto de este archivo porque
# `using .FileResolver` los trae al scope global antes de este `include`.
# Namespacing por proyecto: ver `FileResolver.resolver_ruta_archivo`.

# Directorio base donde se guardarán los resultados cuando no hay proyecto
# activo (fallback histórico; el camino normal usa la carpeta hermana
# "Resultados_<nombre>" calculada a partir de `ruta_proyecto`).
const RESULTADOS_BASE_DIR = Sys.iswindows() ? joinpath(homedir(), "Desktop") : homedir()

# ══════════════════════════════════════════════════════════════════════

"""
Crea una carpeta en el sistema de archivos
"""
function crear_carpeta(ruta_base::String, nombre_carpeta::String)
    try
        # Si ruta_base está vacía, usar el escritorio del usuario
        if isempty(ruta_base)
            if Sys.iswindows()
                ruta_base = joinpath(homedir(), "Desktop")
            else
                ruta_base = homedir()
            end
        end
        
        nueva_ruta = joinpath(ruta_base, nombre_carpeta)
        
        if isdir(nueva_ruta)
            return Dict(
                "success" => false,
                "error" => "La carpeta ya existe",
                "path" => nueva_ruta
            )
        end
        
        mkpath(nueva_ruta)
        
        return Dict(
            "success" => true,
            "path" => nueva_ruta,
            "message" => "Carpeta creada exitosamente"
        )
    catch e
        return Dict(
            "success" => false,
            "error" => string(e)
        )
    end
end

"""
Guarda un archivo en el directorio temporal desde datos Base64
RETORNA la ruta absoluta del archivo guardado
"""
function guardar_archivo_temporal(filename::String, data_base64::String)
    try
        init_temp_dir()
        
        # Decodificar Base64
        file_data = base64decode(data_base64)
        
        # Crear ruta temporal
        temp_path = joinpath(TEMP_DIR, filename)
        
        # Guardar archivo
        write(temp_path, file_data)
        
        # IMPORTANTE: Retornar la ruta ABSOLUTA para que React pueda detectarla
        return Dict(
            "success" => true,
            "temp_path" => temp_path,
            "absolute_path" => temp_path,  # Ruta absoluta del archivo
            "size" => length(file_data)
        )
    catch e
        return Dict(
            "success" => false,
            "error" => string(e)
        )
    end
end

"""
Determina si un archivo es compatible (NIfTI o DICOM)
"""
function is_compatible_file(filename::String)
    ext = lowercase(split(filename, '.')[end])
    # Manejar .nii.gz
    if endswith(lowercase(filename), ".nii.gz")
        return true
    end
    return ext in ["nii", "gz", "dcm", "dicom", "ima"]
end

"""
Lee un archivo NIfTI y devuelve los datos 3D
"""
function read_nifti(filepath::String)
    try
        println("Intentando leer NIfTI: $filepath")
        
        # Intentar leer directamente con NIfTI.jl
        nii = niread(filepath)
        data = nii.raw
        
        println("NIfTI leído exitosamente. Dimensiones: $(size(data))")
        
        header = Dict(
            "dimensions" => size(data),
            "datatype" => string(eltype(data)),
            "voxel_size" => length(nii.header.pixdim) >= 4 ? nii.header.pixdim[2:4] : [1.0, 1.0, 1.0]
        )
        return data, header
    catch e
        println("Error leyendo NIfTI: $e")
        
        # Si falla, intentar descomprimir manualmente si es .gz
        if endswith(lowercase(filepath), ".gz")
            try
                println("Intentando descomprimir archivo .gz manualmente...")
                
                # Leer archivo comprimido
                open(filepath, "r") do io
                    gz = GzipDecompressorStream(io)
                    temp_file = joinpath(TEMP_DIR, "temp_decompressed.nii")
                    write(temp_file, read(gz))
                    close(gz)
                    
                    # Leer archivo descomprimido
                    nii = niread(temp_file)
                    data = nii.raw
                    
                    # Limpiar archivo temporal
                    rm(temp_file, force=true)
                    
                    header = Dict(
                        "dimensions" => size(data),
                        "datatype" => string(eltype(data)),
                        "voxel_size" => [1.0, 1.0, 1.0]
                    )
                    return data, header
                end
            catch e2
                throw(ErrorException("Error leyendo NIfTI después de descompresión: $(e2)"))
            end
        else
            throw(ErrorException("Error leyendo NIfTI: $(e)"))
        end
    end
end

"""
Lee un archivo DICOM y devuelve los datos
"""
function read_dicom_file(filepath::String)
    try
        dcm = dcm_parse(filepath)
        data = dcm[(0x7fe0, 0x0010)]  # Pixel Data
        
        # Obtener dimensiones
        rows = dcm[(0x0028, 0x0010)]
        cols = dcm[(0x0028, 0x0011)]
        
        # Reshape a matriz 2D
        img_data = reshape(data, (cols, rows))
        
        header = Dict(
            "dimensions" => (cols, rows),
            "datatype" => string(eltype(data)),
            "patient_name" => get(dcm, (0x0010, 0x0010), "Unknown")
        )
        
        return img_data, header
    catch e
        throw(ErrorException("Error leyendo DICOM: $(e)"))
    end
end

"""
Extrae un corte específico de un volumen 3D con orientación correcta
orientation: "sagittal", "coronal", "axial"
slice_num: número del corte (1-indexed)
"""
function extract_slice(data::Array{T, 3}, orientation::String, slice_num::Int) where T
    dims = size(data)
    
    if orientation == "sagittal"
        # Corte en el eje X (vista lateral)
        slice_num = clamp(slice_num, 1, dims[1])
        slice = data[slice_num, :, :]
        # Rotar 90° antihorario y luego flip vertical
        rotated = rotr90(slice)
        return reverse(rotated, dims=1)
    elseif orientation == "coronal"
        # Corte en el eje Y (vista frontal)
        slice_num = clamp(slice_num, 1, dims[2])
        slice = data[:, slice_num, :]
        # Rotar 90° antihorario
        return rotr90(slice)
    elseif orientation == "axial"
        # Corte en el eje Z (vista superior)
        slice_num = clamp(slice_num, 1, dims[3])
        slice = data[:, :, slice_num]
        # Rotar 90° a la derecha (antihorario)
        return rotr90(slice)
    else
        throw(ArgumentError("Orientación inválida: $orientation"))
    end
end

"""
Normaliza una imagen a rango 0-255 para visualización
"""
function normalize_for_display(slice::Matrix{T}) where T
    min_val = minimum(slice)
    max_val = maximum(slice)
    
    if min_val == max_val
        return zeros(UInt8, size(slice))
    end
    
    normalized = (slice .- min_val) ./ (max_val - min_val)
    return UInt8.(round.(normalized .* 255))
end

"""
Convierte una matriz de imagen a Base64 PNG para enviar al frontend
"""
function matrix_to_base64_png(img_matrix::Matrix)
    try
        # Normalizar
        normalized = normalize_for_display(img_matrix)
        
        # Convertir a imagen Gray
        img = Gray.(normalized ./ 255.0)
        
        # Guardar en buffer temporal
        buffer = IOBuffer()
        FileIO.save(FileIO.Stream{FileIO.DataFormat{:PNG}}(buffer), img)
        
        # Convertir a Base64
        img_base64 = base64encode(take!(buffer))
        
        return "data:image/png;base64," * img_base64
    catch e
        # Si falla, intentar método alternativo
        println("Advertencia: Error en conversión PNG, usando método alternativo")
        return "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
    end
end

"""
Procesa un archivo médico y devuelve información completa
"""
function process_medical_image(filepath::String)
    if !isfile(filepath)
        return Dict(
            "success" => false,
            "error" => "Archivo no encontrado: $filepath"
        )
    end
    
    filename = basename(filepath)
    println("\n╔═════════════════════════════════════╗")
    println("Procesando: $filename")
    println("Ruta completa: $filepath")
    
    try
        if endswith(lowercase(filename), ".nii.gz") || endswith(lowercase(filename), ".nii")
            println("Tipo detectado: NIfTI")
            data, header = read_nifti(filepath)
            
            return Dict(
                "success" => true,
                "type" => "nifti",
                "data" => data,
                "header" => header,
                "dimensions" => size(data)
            )
        elseif occursin(r"\.(dcm|dicom|ima)$"i, filename)
            println("Tipo detectado: DICOM")
            data, header = read_dicom_file(filepath)
            # DICOM es 2D, lo convertimos a 3D añadiendo una dimensión
            data_3d = reshape(data, (size(data)..., 1))
            
            return Dict(
                "success" => true,
                "type" => "dicom",
                "data" => data_3d,
                "header" => header,
                "dimensions" => size(data_3d)
            )
        else
            return Dict(
                "success" => false,
                "error" => "Formato no soportado"
            )
        end
    catch e
        println("ERROR: $e")
        println(stacktrace(catch_backtrace()))
        return Dict(
            "success" => false,
            "error" => string(e)
        )
    end
end

"""
Limpia archivos temporales antiguos (opcional, para mantenimiento)
"""
function limpiar_cache()
    try
        if isdir(TEMP_DIR)
            for file in readdir(TEMP_DIR)
                filepath = joinpath(TEMP_DIR, file)
                rm(filepath, force=true)
            end
            return Dict("success" => true, "message" => "Cache limpiado")
        end
    catch e
        return Dict("success" => false, "error" => string(e))
    end
end

"""
Guarda una imagen PNG en la carpeta de resultados
ruta_proyecto: ruta del proyecto (si está vacía, usa RESULTADOS_BASE_DIR)
nombre_archivo: nombre del archivo a guardar (ej: "imagen_sagital_45.png")
imagen_base64: string Base64 de la imagen PNG
"""
function guardar_imagen_resultado(ruta_proyecto::String, nombre_archivo::String, imagen_base64::String)
    try
        # Determinar carpeta de resultados
        if !isempty(ruta_proyecto) && isdir(ruta_proyecto)
            # Tenemos proyecto activo - usar carpeta hermana
            ruta_padre = dirname(ruta_proyecto)
            nombre_proyecto = basename(ruta_proyecto)
            carpeta_resultados = joinpath(ruta_padre, "Resultados_$nombre_proyecto")
        else
            # Fallback a Escritorio
            base_path = RESULTADOS_BASE_DIR
            carpeta_resultados = joinpath(base_path, "Resultados")
        end
        
        carpeta_imagenes = joinpath(carpeta_resultados, "imagenes")
        
        # Crear carpetas si no existen
        if !isdir(carpeta_resultados)
            mkpath(carpeta_resultados)
            println("Carpeta creada: $carpeta_resultados")
        end
        
        if !isdir(carpeta_imagenes)
            mkpath(carpeta_imagenes)
            println("Carpeta creada: $carpeta_imagenes")
        end
        
        # Decodificar Base64 y guardar archivo
        img_data = base64decode(imagen_base64)
        ruta_completa = joinpath(carpeta_imagenes, nombre_archivo)
        
        write(ruta_completa, img_data)
        
        println("✅ Imagen guardada: $ruta_completa")
        
        return Dict(
            "success" => true,
            "ruta_completa" => ruta_completa,
            "carpeta_resultados" => carpeta_resultados,
            "message" => "Imagen guardada exitosamente"
        )
    catch e
        println("❌ Error guardando imagen: $e")
        println(stacktrace(catch_backtrace()))
        return Dict(
            "success" => false,
            "error" => string(e)
        )
    end
end

"""
    determinar_ruta_resultados(ruta_proyecto="", nombre_proyecto="") -> String

Calcula (y crea si hace falta) la carpeta de resultados para un análisis:
carpeta hermana `Resultados_<nombre>` con subcarpetas `radiomics/`,
`imagenes/` y `estadisticas/`.

Antes esto vivía en `server.jl` como `determinar_ruta_guardado()` y leía
`PROYECTO_ACTUAL`, una variable global mutada por el último proyecto
abierto por CUALQUIER usuario del servidor — con dos investigadores
trabajando en proyectos distintos al mismo tiempo, el análisis del
segundo terminaba guardando los resultados del primero (o viceversa).
Ahora cada handler recibe `ruta_proyecto` explícito en el body del
request (el frontend ya lo tiene disponible como `project.ruta`) y lo
pasa acá directo — sin estado compartido entre requests.
"""
function determinar_ruta_resultados(ruta_proyecto::AbstractString="", nombre_proyecto::AbstractString="")
    if !isempty(ruta_proyecto) && isdir(ruta_proyecto)
        ruta_padre = dirname(ruta_proyecto)
        nombre = isempty(nombre_proyecto) ? basename(ruta_proyecto) : nombre_proyecto

        ruta_resultados = joinpath(ruta_padre, "Resultados_$nombre")

        mkpath(joinpath(ruta_resultados, "radiomics"))
        mkpath(joinpath(ruta_resultados, "imagenes"))
        mkpath(joinpath(ruta_resultados, "estadisticas"))

        println("📁 Ruta de resultados: $ruta_resultados")
        return ruta_resultados
    else
        base = Sys.iswindows() ? joinpath(homedir(), "Desktop") : homedir()
        ruta_resultados = joinpath(base, "Resultados")
        mkpath(ruta_resultados)
        println("⚠️  Sin proyecto activo en el request, usando fallback: $ruta_resultados")
        return ruta_resultados
    end
end