# Analisis de imagenes de resonancia magnetica
# Modulo en proceso. Por definir si se usa solo Julia o se integra Python en alguna parte del procesamiento.
# Autor: MSL process Backend
# Fecha: 2026
using NIfTI
using Images
using ImageFiltering
using Plot
using KomaMRI
using MRIReco
using MedImages
using ImageMorphology
using CodecXz  # Para leer archivos .nii.gz comprimidos tengo entendido NIIfTI se comunica de manera nativa con esto, si es mas rapido modificar analisis radiomico

"""
		detectar_tipo_archivo(filepath::String) -> Symbol

Detecta tipo de archivo, esto se basa en las funciones del modulo de analisis radiomico
"""
function detectar_tipo_archivo(filepath::String)
    ext = lowercase(splitext(filepath)[2])
    
    if ext in [".nii", ".gz"]
        return :nifti
    elseif ext == ".dcm"
        return :dicom
    else
        return :unknown
    end
end
# Tengo entendido que los MRI vinenen en formato .nii nii .gz o .dcm entonces esto es necesario

"""
    leer_volumen_nifti(filepath::String) -> (Array{Float64, 3}, Tuple{Float64, Float64, Float64})
lee el archivo y retorna el volumen 3D en Float64 y las dimensiones (x,y,z) del voxel 
Lo hace a flujo todo, probare hacerlo asi en vez de lo que esta en el de radiomica, porque 
crear muchos archivos temporales en el disco daña el hardware, corregir si funciona bien hacerlo en flujo
"""
function leer_volumen_nifti(filepath::String)
    try
        #lee el archivo en teoria detecta si es comprimido y lo deberia descomprimir en flujo
        
        nii = niread(filepath, nmap=false) 
       
       # si no funciona probar como lo hace el modulo de analisis radiomico 
       #lee el .raw del archivo y convierte la matriz de datos
       
       volumen = Float64.(nii.raw) 
       
       #guarda temporalmente el header 
       
       pixdim = nii.header.pixdim
       
       # Guarda las dimensiones del voxel en el array voxel_dims usualmente es 1 para ver si es de mano derecha o izq, 2,3 y 4 para las dimensiones 
       
       voxel_dims = (Float64.(pixdim[2]), Float64.(pixdim[3]), Float64.(pixdim[4]))
       
       return volumen, voxel_dims
    catch e 
        throw(ErrorException("Error leyendo NIfTI en la ruta ($filepath): $e"))
    end
end

"""
    leer_volumen_dicom(filepath::String) -> (Array{Float64, 3}, Tuple{Float64, Float64, Float64})

Lee un archivo DICOM y retorna el volumen 3D y las dimensiones de voxel.
"""
function leer_volumen_dicom(filepath::String)
    try
        dcm_data = dcm_parse(filepath)
        
        volumen = Float64.(dcm_data[(0x7fe0, 0x0010)])
        
        pixel_spacing = get(dcm_data, (0x0028, 0x0030), [1.0, 1.0])
        slice_thickness = get(dcm_data, (0x0018, 0x0050), 1.0)
        
        voxel_dims = (Float64(pixel_spacing[1]), Float64(pixel_spacing[2]), Float64(slice_thickness))
        
        if ndims(volumen) == 2
            volumen = reshape(volumen, size(volumen)..., 1)
        end
        
        return volumen, voxel_dims
        
    catch e
        throw(ErrorException("Error leyendo DICOM: $e"))
    end
end
################################################################################################################
# Pre Procesamiento 
"""
Crea una máscara binaria limpia del cuerpo/estructura eliminando 
el ruido del aire exterior.
"""
function crear_mascara_tejido(volumen_normalizado, umbral=0.1)
    # Binarizacion basica por umbral (voxeles con seal vs fondo)
    mascara = volumen_normalizado .> umbral
    
    # Operacion de Clausura (Closing): Cierra pequeos agujeros dentro del tejido
    # Usamos un cubo de conectividad estructural estandar
    mascara_limpia = closing(mascara)
    
    # Operacion de Apertura (Opening): Elimina islas de ruido flotando en el aire exterior
    mascara_limpia = opening(mascara_limpia)
   
    return mascara_limpia
end
