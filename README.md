# MSL Process

Plataforma de análisis de imágenes médicas (NIfTI/DICOM) para el laboratorio.
Permite abrir un proyecto de investigación (carpeta con grupos de sujetos),
visualizar los volúmenes en 3 planos, extraer características radiómicas y
correr análisis estadístico comparando grupos. Un cuarto módulo, **análisis
por grafos**, está en desarrollo.

```
┌───────────────────┐             
│  Frontend (React) │     
│  Vite + Tailwind  │     
└───────────────────┘                        
        ▲ │HTTP :8000 
   JSON │ ▼          
┌───────────────────┐           Volumen Docker `./projects` 
│  Backend (Julia)  │  ───────▶ (archivos NIfTI/DICOM/Excel
│  HTTP.jl server   │             reales del laboratorio)
└───────────────────┘
        ▲ │libpq
        │ ▼          
  ┌──────────────┐
  │  PostgreSQL  │
  │  (metadatos) │
  └──────────────┘
```

El backend no guarda los archivos médicos en la base de datos: PostgreSQL solo
indexa metadatos (proyectos, grupos, rutas). Los archivos viven en disco,
dentro de `./projects` (montado por Docker), y el backend los lee por su ruta
absoluta.

## Stack

| Capa       | Tecnología                                                        |
|------------|--------------------------------------------------------------------|
| Frontend   | React 18 + Vite 5 + Tailwind CSS, servido por nginx en producción  |
| Backend    | Julia 1.10 + [HTTP.jl](https://github.com/JuliaWeb/HTTP.jl) (servidor propio, sin framework) |
| Base de datos | PostgreSQL 16 (vía `LibPQ.jl`)                                  |
| Imágenes médicas | `NIfTI.jl`, `DICOM.jl`, `Images.jl`                           |
| Radiómica / estadística | Implementadas a mano en Julia puro (sin PyCall): `StatsBase`, `HypothesisTests`, `Distributions`, `MultivariateStats` |
| Orquestación | Docker Compose (3 servicios: `postgres`, `backend`, `frontend`)  |

## Levantar el proyecto (Docker — forma recomendada)

```bash
docker compose up --build
```

Esto levanta:
- `postgres` — PostgreSQL 16, con healthcheck antes de dejar arrancar al backend.
- `backend` — Julia, puerto **8000**, con hilos automáticos (`JULIA_NUM_THREADS: auto`).
- `frontend` — build estático de Vite servido por nginx, puerto **3000**.

Accede a **http://localhost:3000**. El frontend detecta solo la URL del
backend a partir del hostname del navegador (ver `frontend/src/services/api.js`),
así que la misma imagen sirve tanto para `localhost` como para acceso por IP
en la red del laboratorio.

Volúmenes persistentes (carpetas del host, junto a `docker-compose.yml`):

| Carpeta      | Contenido                                                |
|--------------|-----------------------------------------------------------|
| `./projects` | Proyectos de investigación (esto es lo que hay que respaldar) |
| `./output`   | Resultados sueltos (fallback cuando no hay proyecto activo) |
| `./cache`    | Caché temporal de archivos subidos desde el navegador     |

## Desarrollo local (sin Docker)

Backend:
```bash
cd backend
julia --project=. -e 'using Pkg; Pkg.instantiate()'
# Necesita un PostgreSQL corriendo y accesible con las variables DB_* (ver db.jl)
julia -t auto --project=. server.jl
```

Frontend:
```bash
cd frontend
npm install
npm run dev          # http://localhost:3000, con hot-reload
```

Para apuntar el frontend a un backend en otra máquina, define
`VITE_API_URL` en un `.env.local` dentro de `frontend/`.

## Formatos de archivo soportados

| Formato | Extensiones | Usado en |
|---|---|---|
| NIfTI | `.nii`, `.nii.gz` | Visualización, Radiómica, Estadística |
| DICOM | `.dcm`, `.dicom`, `.ima` | Visualización, Radiómica, Estadística |
| Excel | `.xlsx`, `.xls` | Estadística (comparar hojas de datos ya tabuladas) |

Para el análisis estadístico por imágenes, cada proyecto debe organizarse como:

```
MiProyecto/
├── Grupo_1/
│   ├── sujeto_01.nii.gz
│   └── sujeto_02.nii.gz
└── Grupo_2/
    ├── sujeto_03.nii.gz
    └── sujeto_04.nii.gz
```

Un archivo directamente bajo la raíz del proyecto (sin carpeta de grupo) o
anidado en una subcarpeta adicional es ignorado por el módulo de estadística
(la interfaz avisa cuáles y por qué).

## Los 3 módulos actuales (+ 1 en construcción)

1. **Visualización** — carga un volumen y muestra los 3 cortes (sagital,
   coronal, axial) con zoom/pan y exportación a PNG.
2. **Radiómica** — extrae ~90 características por archivo (primer orden,
   forma, GLCM, GLRLM, GLSZM) y exporta a Excel. Soporta modo paralelo
   (`Threads.@spawn` por archivo).
3. **Estadística** — compara 2+ grupos con selección automática de prueba
   paramétrica/no paramétrica según normalidad (Shapiro-Wilk): t-test,
   ANOVA, Mann-Whitney, Kruskal-Wallis, Tukey HSD, correlación, matriz de
   correlación, pruebas de varianza.
4. **Grafos** *(en desarrollo)* — el frontend ya tiene la pestaña reservada
   (`frontend/src/modules/graphs/`), sin conectar todavía. El plan de
   preprocesamiento e implementación vive aparte; ver el manual técnico para
   dónde engancha en la arquitectura actual.

## API — resumen

Todos los endpoints devuelven JSON con al menos `{"success": bool}`. Detalle
completo de payloads en `frontend/src/services/api.js` (única capa del
frontend que le habla al backend) y en `backend/src/handlers/`.

| Método | Ruta | Qué hace |
|---|---|---|
| GET | `/api/test`, `/api/info` | Salud / info del servidor |
| POST | `/api/cambiar-modo` | Cambia modo de operación (reservado, no usado hoy) |
| GET | `/api/jobs/:id` | Progreso de un análisis asíncrono |
| GET | `/api/proyectos` | Lista proyectos guardados (BD) |
| GET / DELETE | `/api/proyecto/:id` | Abrir / eliminar proyecto persistente |
| PUT | `/api/proyecto/:id/renombrar` | Renombra proyecto (carpeta + BD) |
| PUT | `/api/proyecto/:id/carpeta` | Renombra una carpeta/grupo dentro del proyecto |
| POST | `/api/crear-proyecto` | Crea proyecto + grupos iniciales |
| POST | `/api/agregar-grupos` | Agrega carpetas de grupo a un proyecto existente |
| POST | `/api/seleccionar-carpeta-local` | Selector nativo de carpetas (backend, requiere `NativeFileDialog.jl`) |
| POST | `/api/agregar-archivos` | Copia archivos (Base64) a una carpeta del proyecto |
| POST | `/api/upload-file` | Sube un archivo al caché temporal del servidor |
| POST | `/api/check-file` | Verifica si un nombre de archivo es compatible |
| DELETE | `/api/limpiar-cache` | Limpia caché temporal + imágenes en memoria |
| POST | `/api/load-image`, `/api/get-slice` | Carga un volumen / extrae un corte 2D |
| POST | `/api/guardar-imagen` | Guarda un corte como PNG en `Resultados_<proyecto>/imagenes` |
| POST | `/api/analisis-radiomico` | Extrae features radiómicas de N archivos |
| POST | `/api/analisis-estadistico` | Corre pruebas estadísticas entre grupos |

## Documentación para desarrolladores

Si te vas a unir al desarrollo de esta app (incluyendo el módulo de grafos),
lee **[`docs/MANUAL_DESARROLLO.md`](docs/MANUAL_DESARROLLO.md)** 
