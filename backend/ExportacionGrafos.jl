# ==============================================================================
# ExportacionGrafos.jl — Exportar los datos de los grafos para analizarlos fuera
# ==============================================================================
#
# Cada análisis deja, por sujeto, un JSON en `Resultados_<proyecto>/grafos/` con todo:
# metadatos, parámetros, preprocesamiento, el grafo completo (nodos y aristas) y las
# 54 características avanzadas. Este archivo los convierte en tablas "ordenadas" (una
# fila por observación, una columna por variable), listas para R, Python, Excel, etc.:
#
#   sujetos : una fila por sujeto — metadatos (grupo, resolución, región), parámetros
#             usados, métricas básicas y las 54 características avanzadas. Es la tabla
#             que se compara entre grupos.
#   aristas : una fila por arista de cada sujeto (radio, longitud, tortuosidad,
#             direcciones de salida). Para analizar distribuciones por arista, ajustar
#             modelos con el sujeto como efecto aleatorio, etc.
#   nodos   : una fila por nodo de cada sujeto (tipo, grado, posición).
#
# Formatos: CSV (UTF-8 con BOM para que Excel respete los acentos; coma como separador,
# punto decimal; celda vacía = valor no calculable) y un Excel con una hoja por tabla.
#
# Por seguridad, solo se leen archivos `grafo_*.json` que estén dentro de una carpeta
# `grafos/` de una carpeta `Resultados_*` (los que escribe el propio análisis): el
# endpoint no debe poder leer rutas arbitrarias del servidor.
#
# Depende de `ORDEN_CARACTERISTICAS_GRAFOS` (MetricasGrafos.jl). Autoprueba:
#   julia --project=. -e 'include("MetricasGrafos.jl"); include("ExportacionGrafos.jl"); autoprueba_exportacion()'
# ==============================================================================

using Dates
using XLSX
using JSON3
using Base64

# ------------------------------------------------------------------------------
# Acceso seguro a documentos JSON anidados
# ------------------------------------------------------------------------------

"""`d[claves[1]][claves[2]]...`, o `nothing` si algún nivel no existe."""
function _exp_get(d, claves...)
    x = d
    for k in claves
        (x isa AbstractDict && haskey(x, k)) || return nothing
        x = x[k]
    end
    return x
end

"""Elemento `i` de un vector (p. ej. `voxel_dims_mm`), o `nothing`."""
_exp_elem(v, i::Int) = (v isa AbstractVector && length(v) >= i) ? v[i] : nothing

_exp_unir(v, sep) = v isa AbstractVector ? join(string.(v), sep) : v

"""Convierte lo que devuelve `JSON3.read` (objetos con claves Symbol, arreglos propios) en `Dict{String,Any}` / `Vector{Any}` comunes."""
_a_dict(x::AbstractDict) = Dict{String,Any}(string(k) => _a_dict(v) for (k, v) in x)
_a_dict(x::AbstractVector) = Any[_a_dict(v) for v in x]
_a_dict(x) = x

# ------------------------------------------------------------------------------
# Tablas
# ------------------------------------------------------------------------------

const _EXP_PREPROC = ["escalas_mm", "umbral_vesselness", "origen_umbral", "voxeles_vasculares", "fraccion_volumen",
                      "componentes_antes", "componentes_despues", "voxeles_cavidades_rellenadas"]
const _EXP_PARAMS = ["longitud_min_rama_mm", "factor_radio_poda", "ventana_suavizado", "longitud_min_tortuosidad_mm"]
const _EXP_BASICAS = ["num_nodos", "num_bifurcaciones", "num_puntas", "num_aristas", "longitud_vascular_total_mm",
                      "radio_promedio_mm", "tortuosidad_promedio", "num_componentes", "ciclos_independientes"]

"""Columnas de la tabla de sujetos, en orden, como pares `(nombre, extractor(doc))`."""
function _columnas_sujetos()
    cols = Tuple{String,Function}[
        ("archivo", d -> _exp_get(d, "archivo")),
        ("grupo", d -> _exp_get(d, "grupo")),
        ("ruta_origen", d -> _exp_get(d, "ruta_origen")),
        ("dim_x", d -> _exp_elem(_exp_get(d, "dimensiones"), 1)),
        ("dim_y", d -> _exp_elem(_exp_get(d, "dimensiones"), 2)),
        ("dim_z", d -> _exp_elem(_exp_get(d, "dimensiones"), 3)),
        ("voxel_x_mm", d -> _exp_elem(_exp_get(d, "voxel_dims_mm"), 1)),
        ("voxel_y_mm", d -> _exp_elem(_exp_get(d, "voxel_dims_mm"), 2)),
        ("voxel_z_mm", d -> _exp_elem(_exp_get(d, "voxel_dims_mm"), 3)),
        ("region", d -> _exp_get(d, "region", "origen")),
        ("bbox", d -> _exp_unir(_exp_get(d, "region", "bbox_usado"), ",")),
    ]
    for k in _EXP_PREPROC
        push!(cols, ("preproc_" * k, d -> _exp_unir(_exp_get(d, "preprocesamiento", k), ";")))
    end
    for k in _EXP_PARAMS
        push!(cols, ("param_" * k, d -> _exp_get(d, "parametros_grafo", k)))
    end
    for k in _EXP_BASICAS
        push!(cols, ("basica_" * k, d -> _exp_get(d, "grafo", "metricas", k)))
    end
    for k in ORDEN_CARACTERISTICAS_GRAFOS
        push!(cols, (k, d -> _exp_get(d, "avanzadas", "caracteristicas", k)))
    end
    return cols
end

"""`(columnas, filas)` de la tabla de sujetos: una fila por documento."""
function tabla_sujetos(docs)
    cols = _columnas_sujetos()
    filas = Vector{Any}[Any[f(d) for (_, f) in cols] for d in docs]
    return String[c for (c, _) in cols], filas
end

const EXPORT_COLUMNAS_ARISTAS = ["archivo", "grupo", "arista_id", "nodo_u", "nodo_v", "longitud_mm", "radio_medio_mm",
                                 "tortuosidad", "n_voxeles", "dir_u_x", "dir_u_y", "dir_u_z", "dir_v_x", "dir_v_y", "dir_v_z"]

"""Filas de aristas de un documento (una por arista)."""
function filas_aristas(doc)
    ar = _exp_get(doc, "grafo", "aristas")
    filas = Vector{Any}[]
    ar isa AbstractVector || return filas
    for a in ar
        du = get(a, "dir_u", nothing)
        dv = get(a, "dir_v", nothing)
        push!(filas, Any[
            _exp_get(doc, "archivo"), _exp_get(doc, "grupo"),
            get(a, "id", nothing), get(a, "u", nothing), get(a, "v", nothing),
            get(a, "longitud_mm", nothing), get(a, "radio_medio_mm", nothing), get(a, "tortuosidad", nothing), get(a, "n_voxeles", nothing),
            _exp_elem(du, 1), _exp_elem(du, 2), _exp_elem(du, 3), _exp_elem(dv, 1), _exp_elem(dv, 2), _exp_elem(dv, 3),
        ])
    end
    return filas
end

const EXPORT_COLUMNAS_NODOS = ["archivo", "grupo", "nodo_id", "tipo", "grado", "pos_x_mm", "pos_y_mm", "pos_z_mm",
                               "pos_x_vox", "pos_y_vox", "pos_z_vox"]

"""Filas de nodos de un documento (una por nodo)."""
function filas_nodos(doc)
    nd = _exp_get(doc, "grafo", "nodos")
    filas = Vector{Any}[]
    nd isa AbstractVector || return filas
    for n in nd
        pm = get(n, "posicion_mm", nothing)
        pv = get(n, "posicion_voxel", nothing)
        push!(filas, Any[
            _exp_get(doc, "archivo"), _exp_get(doc, "grupo"),
            get(n, "id", nothing), get(n, "tipo", nothing), get(n, "grado", nothing),
            _exp_elem(pm, 1), _exp_elem(pm, 2), _exp_elem(pm, 3), _exp_elem(pv, 1), _exp_elem(pv, 2), _exp_elem(pv, 3),
        ])
    end
    return filas
end

"""`(columnas, filas)` de una tabla ("sujetos", "aristas" o "nodos") sobre todos los documentos."""
function tabla_por_nombre(docs, tabla::AbstractString)
    if tabla == "sujetos"
        return tabla_sujetos(docs)
    elseif tabla == "aristas" || tabla == "nodos"
        filas = Vector{Any}[]
        for d in docs
            append!(filas, tabla == "aristas" ? filas_aristas(d) : filas_nodos(d))
        end
        return (tabla == "aristas" ? EXPORT_COLUMNAS_ARISTAS : EXPORT_COLUMNAS_NODOS), filas
    end
    error("tabla desconocida: '$tabla' (esperado sujetos, aristas o nodos)")
end

# ------------------------------------------------------------------------------
# CSV
# ------------------------------------------------------------------------------

"""Una celda como texto de CSV: vacío si no hay valor; comillas dobles si el texto trae coma, comilla o salto de línea."""
function _csv_celda(v)
    v === nothing && return ""
    v isa Bool && return v ? "true" : "false"
    if v isa AbstractFloat
        return isfinite(v) ? string(v) : ""
    end
    v isa Integer && return string(v)
    s = string(v)
    if occursin(r"[\",\n\r]", s)
        return "\"" * replace(s, "\"" => "\"\"") * "\""
    end
    return s
end

"""Tabla como texto CSV (UTF-8 con BOM, separador coma, punto decimal)."""
function tabla_a_csv(columnas, filas)
    io = IOBuffer()
    write(io, "\ufeff")
    println(io, join((_csv_celda(c) for c in columnas), ","))
    for fila in filas
        println(io, join((_csv_celda(x) for x in fila), ","))
    end
    return String(take!(io))
end

# ------------------------------------------------------------------------------
# Excel
# ------------------------------------------------------------------------------

"""Valor listo para una celda de Excel, o `nothing` para dejarla vacía."""
function _xlsx_valor(v)
    v === nothing && return nothing
    v isa AbstractFloat && return isfinite(v) ? v : nothing
    (v isa Integer || v isa Bool || v isa AbstractString) && return v
    return string(v)
end

function _escribir_hoja!(hoja, columnas, filas)
    for (c, nombre) in enumerate(columnas)
        hoja[XLSX.CellRef(1, c)] = nombre
    end
    for (r, fila) in enumerate(filas)
        for (c, v) in enumerate(fila)
            valor = _xlsx_valor(v)
            valor === nothing && continue
            hoja[XLSX.CellRef(r + 1, c)] = valor
        end
    end
    return nothing
end

"""Escribe un Excel con una hoja por tabla (Sujetos, Aristas, Nodos) y una hoja "Leeme"."""
function escribir_xlsx(ruta::AbstractString, docs)
    XLSX.openxlsx(ruta, mode="w") do xf
        hoja = xf[1]
        XLSX.rename!(hoja, "Sujetos")
        cols, filas = tabla_sujetos(docs)
        _escribir_hoja!(hoja, cols, filas)

        for (nombre, tabla) in (("Aristas", "aristas"), ("Nodos", "nodos"))
            XLSX.addsheet!(xf, nombre)
            c, f = tabla_por_nombre(docs, tabla)
            _escribir_hoja!(xf[nombre], c, f)
        end

        XLSX.addsheet!(xf, "Leeme")
        leeme = xf["Leeme"]
        lineas = [
            "Exportación del módulo de grafos",
            "Generado: $(Dates.format(now(), "dd/mm/yyyy HH:MM:SS"))",
            "Sujetos: $(length(docs))",
            "Hoja Sujetos: una fila por sujeto (metadatos, parámetros, métricas básicas y las características avanzadas).",
            "Hoja Aristas: una fila por arista de cada sujeto.",
            "Hoja Nodos: una fila por nodo de cada sujeto.",
            "Celda vacía = valor no calculable (no es cero).",
            "grupo = carpeta que contiene al archivo. Definiciones de cada métrica: docs/CAMBIOS_PARA_GRAFOS.md.",
        ]
        for (i, l) in enumerate(lineas)
            leeme[XLSX.CellRef(i, 1)] = l
        end
    end
    return nothing
end

# ------------------------------------------------------------------------------
# Punto de entrada
# ------------------------------------------------------------------------------

"""¿Es `ruta` un `grafo_*.json` dentro de `Resultados_*/grafos/`? (lo único que se deja leer)"""
function _ruta_exportable(ruta::AbstractString)
    r = abspath(ruta)
    endswith(r, ".json") || return false
    startswith(basename(r), "grafo_") || return false
    carpeta = dirname(r)
    basename(carpeta) == "grafos" || return false
    return startswith(basename(dirname(carpeta)), "Resultados")
end

"""
    exportar_grafos(rutas_json, formato, tabla, dir_salida) -> Dict

`formato`: "csv" (una `tabla`: "sujetos", "aristas" o "nodos") o "xlsx" (todas las tablas en un libro).
Guarda el archivo en `dir_salida` (si se da) y devuelve su contenido en Base64 para que el navegador lo descargue.
"""
function exportar_grafos(rutas_json::Vector{String}, formato::AbstractString, tabla::AbstractString,
                         dir_salida::Union{AbstractString,Nothing})
    docs = Dict{String,Any}[]
    omitidos = String[]
    for r in rutas_json
        if _ruta_exportable(r) && isfile(r)
            push!(docs, _a_dict(JSON3.read(read(r, String))))
        else
            push!(omitidos, r)
        end
    end
    isempty(docs) && error("No se pudo leer ningún grafo exportable (¿se movieron o borraron los JSON de Resultados_*/grafos?)")

    marca = Dates.format(now(), "yyyymmdd_HHMMSS")
    if dir_salida !== nothing
        mkpath(dir_salida)
    end
    carpeta = dir_salida === nothing ? tempdir() : String(dir_salida)

    if formato == "csv"
        columnas, filas = tabla_por_nombre(docs, tabla)
        nombre = "grafos_$(tabla)_$(marca).csv"
        ruta = joinpath(carpeta, nombre)
        write(ruta, tabla_a_csv(columnas, filas))
        mime = "text/csv"
    elseif formato == "xlsx"
        nombre = "grafos_$(marca).xlsx"
        ruta = joinpath(carpeta, nombre)
        escribir_xlsx(ruta, docs)
        mime = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    else
        error("formato desconocido: '$formato' (esperado csv o xlsx)")
    end

    return Dict{String,Any}(
        "success" => true,
        "nombre" => nombre,
        "mime" => mime,
        "contenido_base64" => base64encode(read(ruta)),
        "ruta" => dir_salida === nothing ? nothing : ruta,
        "n_sujetos" => length(docs),
        "omitidos" => omitidos,
    )
end

# ==============================================================================
# AUTOPRUEBA
# ==============================================================================

function _doc_de_prueba(archivo, grupo)
    return Dict{String,Any}(
        "archivo" => archivo, "ruta_origen" => "/p/$grupo/$archivo", "grupo" => grupo,
        "voxel_dims_mm" => Any[1.0, 1.0, 3.0], "dimensiones" => Any[10, 20, 5],
        "region" => Dict{String,Any}("bbox_usado" => Any[1, 10, 2, 20, 1, 5], "origen" => "bbox manual"),
        "preprocesamiento" => Dict{String,Any}("escalas_mm" => Any[1.0, 2.0], "umbral_vesselness" => 0.1, "voxeles_vasculares" => 123),
        "parametros_grafo" => Dict{String,Any}("longitud_min_rama_mm" => 3.0),
        "grafo" => Dict{String,Any}(
            "metricas" => Dict{String,Any}("num_nodos" => 3, "tortuosidad_promedio" => nothing),
            "nodos" => Any[Dict{String,Any}("id" => 1, "tipo" => "punta", "grado" => 1, "posicion_mm" => Any[1.0, 2.0, 3.0], "posicion_voxel" => Any[1.0, 2.0, 1.0]),
                           Dict{String,Any}("id" => 2, "tipo" => "bifurcacion", "grado" => 3, "posicion_mm" => Any[4.0, 5.0, 6.0], "posicion_voxel" => nothing)],
            "aristas" => Any[Dict{String,Any}("id" => 1, "u" => 1, "v" => 2, "longitud_mm" => 5.5, "radio_medio_mm" => 2.0, "tortuosidad" => nothing,
                                              "n_voxeles" => 6, "dir_u" => Any[0.0, 0.0, 1.0], "dir_v" => Any[0.0, 0.0, -1.0])],
        ),
        "avanzadas" => Dict{String,Any}("caracteristicas" => Dict{String,Any}("radio_media_mm" => 2.5, "strahler_max" => 4, "angulo_hijas_media_deg" => nothing)),
    )
end

function autoprueba_exportacion()
    ok = true
    chequear = function (nombre, cond)
        println(cond ? "  ✅ " : "  ❌ ", nombre)
        return cond
    end
    println("Autoprueba de la exportación")

    docs = [_doc_de_prueba("a.nii.gz", "Sanos"), _doc_de_prueba("b,\"raro\".nii", "Enfermos")]

    cols, filas = tabla_sujetos(docs)
    ok &= chequear("sujetos: una fila por documento y tantas celdas como columnas", length(filas) == 2 && all(f -> length(f) == length(cols), filas))
    ok &= chequear("sujetos: columnas únicas y las características avanzadas al final, en orden",
                   length(unique(cols)) == length(cols) && cols[end-length(ORDEN_CARACTERISTICAS_GRAFOS)+1:end] == ORDEN_CARACTERISTICAS_GRAFOS)
    pos(n) = findfirst(==(n), cols)
    ok &= chequear("sujetos: grupo, voxel y dimensiones bien ubicados",
                   filas[1][pos("grupo")] == "Sanos" && filas[1][pos("voxel_z_mm")] == 3.0 && filas[1][pos("dim_y")] == 20 && filas[1][pos("bbox")] == "1,10,2,20,1,5")
    ok &= chequear("sujetos: lo que falta queda vacío (nothing), no 0",
                   filas[1][pos("basica_tortuosidad_promedio")] === nothing && filas[1][pos("angulo_hijas_media_deg")] === nothing && filas[1][pos("strahler_max")] == 4)
    ok &= chequear("sujetos: vectores en una sola celda (escalas con ';')", filas[1][pos("preproc_escalas_mm")] == "1.0;2.0")

    ca, fa = tabla_por_nombre(docs, "aristas")
    cn, fn = tabla_por_nombre(docs, "nodos")
    ok &= chequear("aristas: 2 filas (1 por sujeto), 15 columnas, dirección en 3 columnas", length(fa) == 2 && length(ca) == 15 && all(f -> length(f) == 15, fa) && fa[1][12] == 1.0)
    ok &= chequear("nodos: 4 filas (2 por sujeto), 11 columnas; posición faltante vacía", length(fn) == 4 && all(f -> length(f) == 11, fn) && fn[2][9] === nothing)

    csv = tabla_a_csv(["a", "b,c", "d"], [Any[1, "x\"y", nothing], Any[2.5, "línea1\nlínea2", true], Any[NaN, "ñ", 3]])
    lineas = split(csv, "\n")
    ok &= chequear("CSV: BOM al inicio y cabecera con la coma entre comillas", startswith(csv, "\ufeff") && occursin("a,\"b,c\",d", lineas[1]))
    ok &= chequear("CSV: comillas duplicadas, salto de línea entre comillas, vacío y booleano",
                   occursin("1,\"x\"\"y\",", csv) && occursin("\"línea1\nlínea2\"", csv) && occursin(",true", csv))
    ok &= chequear("CSV: NaN queda vacío y los acentos se conservan", occursin("\n,ñ,3", csv))

    ok &= chequear("solo se leen grafo_*.json dentro de Resultados_*/grafos/",
                   _ruta_exportable("/p/Resultados_X/grafos/grafo_a_20260101_000000.json") &&
                   !_ruta_exportable("/etc/passwd") && !_ruta_exportable("/p/Resultados_X/grafos/otro.json") &&
                   !_ruta_exportable("/p/Proyecto/grafos/grafo_a.json") && !_ruta_exportable("/p/Resultados_X/grafos/grafo_a.txt"))

    # ida y vuelta por disco (JSON -> exportación)
    base = mktempdir()
    dir = joinpath(base, "Resultados_Prueba", "grafos")
    mkpath(dir)
    rutas = String[]
    for (i, d) in enumerate(docs)
        r = joinpath(dir, "grafo_s$(i)_20260101_000000.json")
        open(r, "w") do io
            JSON3.write(io, d)
        end
        push!(rutas, r)
    end
    res = exportar_grafos(rutas, "csv", "sujetos", dir)
    texto = String(base64decode(res["contenido_base64"]))
    ok &= chequear("exportar CSV: 2 sujetos, archivo guardado y contenido en Base64 idéntico al guardado",
                   res["n_sujetos"] == 2 && res["ruta"] !== nothing && isfile(res["ruta"]) && texto == read(res["ruta"], String) && occursin("Sanos", texto))
    res2 = exportar_grafos(vcat(rutas, ["/etc/passwd"]), "xlsx", "sujetos", dir)
    ok &= chequear("exportar Excel: genera el libro y omite la ruta no permitida",
                   res2["success"] == true && isfile(res2["ruta"]) && res2["omitidos"] == ["/etc/passwd"] && filesize(res2["ruta"]) > 0)
    rm(base; recursive=true, force=true)

    println(ok ? "✅ Autoprueba de la exportación: todo en orden" : "❌ Autoprueba de la exportación: HAY FALLOS")
    return ok
end
