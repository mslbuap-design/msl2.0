import { useEffect, useRef, useState } from 'react';
import { X } from 'lucide-react';
import * as api from '../../services/api.js';
import Button from '../../components/ui/Button.jsx';
import {
  VISTAS,
  aspectoVista,
  bboxCompleto,
  bboxDesdeArrastre,
  bboxEsCompleto,
  describirBbox,
  normalizarBbox,
  rectanguloDeBbox,
  totalCortes,
} from './graphUtils.js';

const ORDEN_VISTAS = ['axial', 'coronal', 'sagittal'];

/**
 * Una vista ortogonal con el recorte superpuesto. Arrastrar sobre la imagen
 * dibuja un rectángulo nuevo: reemplaza los dos ejes visibles en esa vista y
 * conserva el tercero. El deslizador de abajo cambia el corte que se muestra.
 */
function VistaRecorte({ nombreArchivo, orientacion, dims, voxel, bbox, corte, onCorte, onBbox }) {
  const [imagen, setImagen] = useState(null);
  const [arrastre, setArrastre] = useState(null); // { ini, fin } en fracciones 0–1 de la imagen
  const total = totalCortes(orientacion, dims);

  // El corte se pide con un pequeño retraso para no saturar al mover el deslizador.
  useEffect(() => {
    let cancelado = false;
    const temporizador = setTimeout(async () => {
      try {
        const r = await api.getSlice({ filename: nombreArchivo, orientation: orientacion, slice: corte });
        if (!cancelado && r.success) setImagen(r.image);
      } catch {
        // se conserva la imagen anterior
      }
    }, 120);
    return () => {
      cancelado = true;
      clearTimeout(temporizador);
    };
  }, [nombreArchivo, orientacion, corte]);

  const fraccion = (e) => {
    const r = e.currentTarget.getBoundingClientRect();
    return {
      x: Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)),
      y: Math.min(1, Math.max(0, (e.clientY - r.top) / r.height)),
    };
  };

  const alPresionar = (e) => {
    const f = fraccion(e);
    setArrastre({ ini: f, fin: f });
    e.currentTarget.setPointerCapture(e.pointerId);
  };
  const alMover = (e) => {
    if (arrastre) setArrastre({ ini: arrastre.ini, fin: fraccion(e) });
  };
  const alSoltar = () => {
    if (!arrastre) return;
    const { ini, fin } = arrastre;
    setArrastre(null);
    if (Math.abs(fin.x - ini.x) > 0.01 && Math.abs(fin.y - ini.y) > 0.01) {
      onBbox(bboxDesdeArrastre(orientacion, dims, bbox, ini, fin));
    }
  };

  const rect = arrastre
    ? {
        left: Math.min(arrastre.ini.x, arrastre.fin.x),
        top: Math.min(arrastre.ini.y, arrastre.fin.y),
        width: Math.abs(arrastre.fin.x - arrastre.ini.x),
        height: Math.abs(arrastre.fin.y - arrastre.ini.y),
      }
    : rectanguloDeBbox(orientacion, dims, bbox);

  return (
    <div className="min-w-0">
      <p className="text-xs font-medium text-ink mb-1">{VISTAS[orientacion].nombre}</p>
      <div
        className="relative bg-black rounded overflow-hidden cursor-crosshair select-none touch-none"
        style={{ aspectRatio: String(aspectoVista(orientacion, dims, voxel)) }}
        onPointerDown={alPresionar}
        onPointerMove={alMover}
        onPointerUp={alSoltar}
        onPointerCancel={() => setArrastre(null)}
      >
        {imagen && (
          <img
            src={imagen}
            alt={`Corte ${VISTAS[orientacion].nombre}`}
            draggable={false}
            className="absolute inset-0 w-full h-full pointer-events-none"
          />
        )}
        <div
          className="absolute border-2 border-amber-400 bg-amber-300/10 pointer-events-none"
          style={{
            left: `${rect.left * 100}%`,
            top: `${rect.top * 100}%`,
            width: `${rect.width * 100}%`,
            height: `${rect.height * 100}%`,
          }}
        />
      </div>
      <div className="flex items-center gap-2 mt-1.5">
        <input
          type="range"
          min={1}
          max={total}
          value={corte}
          onChange={(e) => onCorte(Number(e.target.value))}
          aria-label={`Corte ${VISTAS[orientacion].nombre}`}
          className="flex-1 accent-accent"
        />
        <span className="text-xs text-muted font-data w-14 text-right">
          {corte}/{total}
        </span>
      </div>
    </div>
  );
}

/** Rango [mínimo, máximo] de un eje, con dos deslizadores. */
function RangoEje({ nombre, n, minimo, maximo, onCambio }) {
  return (
    <div className="space-y-0.5">
      <div className="flex justify-between text-xs">
        <span className="font-medium text-ink">{nombre}</span>
        <span className="text-muted font-data">
          {minimo} – {maximo} (de {n})
        </span>
      </div>
      <input
        type="range"
        min={1}
        max={n}
        value={minimo}
        onChange={(e) => {
          const v = Number(e.target.value);
          onCambio(v, Math.max(v, maximo));
        }}
        aria-label={`${nombre} mínimo`}
        className="w-full accent-accent"
      />
      <input
        type="range"
        min={1}
        max={n}
        value={maximo}
        onChange={(e) => {
          const v = Number(e.target.value);
          onCambio(Math.min(minimo, v), v);
        }}
        aria-label={`${nombre} máximo`}
        className="w-full accent-accent"
      />
    </div>
  );
}

/**
 * Control manual de la región de análisis (Paso 0): se elige el recorte sobre
 * las 3 vistas ortogonales de un archivo de referencia. El recorte queda en
 * vóxeles y se aplica igual a todos los archivos del análisis.
 *
 * @param {{archivos: Object[], bboxInicial: number[]|null, onAplicar: (bbox: number[]|null) => void, onCerrar: () => void}} props
 */
export default function RegionModal({ archivos, bboxInicial, onAplicar, onCerrar }) {
  const [indiceArchivo, setIndiceArchivo] = useState(0);
  const [dims, setDims] = useState(null); // [nx, ny, nz]
  const [voxel, setVoxel] = useState([1, 1, 1]);
  const [bbox, setBbox] = useState(null);
  const [cortes, setCortes] = useState({ axial: 1, coronal: 1, sagittal: 1 });
  const [cargando, setCargando] = useState(true);
  const [error, setError] = useState(null);

  const bboxInicialRef = useRef(bboxInicial);
  const archivo = archivos[indiceArchivo];
  const nombreArchivo = archivo.fullPath || archivo.name;

  useEffect(() => {
    let cancelado = false;
    setCargando(true);
    setError(null);
    setDims(null);
    (async () => {
      try {
        const r = await api.loadImage(nombreArchivo);
        if (cancelado) return;
        if (!r.success) {
          setError(r.error || 'No se pudo cargar el volumen');
          return;
        }
        const d = r.dimensions.map(Number);
        const vs = r.header?.voxel_size;
        setVoxel(Array.isArray(vs) && vs.length >= 3 ? vs.slice(0, 3).map(Number) : [1, 1, 1]);
        setCortes({
          axial: Math.ceil(d[2] / 2),
          coronal: Math.ceil(d[1] / 2),
          sagittal: Math.ceil(d[0] / 2),
        });
        setBbox((previo) => normalizarBbox(previo ?? bboxInicialRef.current ?? bboxCompleto(d), d));
        setDims(d);
      } catch {
        if (!cancelado) setError('Error de conexión al cargar el volumen');
      } finally {
        if (!cancelado) setCargando(false);
      }
    })();
    return () => {
      cancelado = true;
    };
  }, [nombreArchivo]);

  const aplicar = () => {
    if (!dims || !bbox) return;
    onAplicar(bboxEsCompleto(bbox, dims) ? null : bbox);
  };

  const cambiarEje = (eje, minimo, maximo) => {
    setBbox((previo) => {
      const nuevo = [...previo];
      nuevo[2 * eje] = minimo;
      nuevo[2 * eje + 1] = maximo;
      return nuevo;
    });
  };

  return (
    <div className="fixed inset-0 z-50 bg-ink/40 flex items-center justify-center p-4">
      <div className="bg-surface rounded-xl shadow-overlay border border-line w-full max-w-6xl flex flex-col max-h-[92vh]">
        <div className="flex items-center justify-between px-5 py-4 border-b border-line shrink-0">
          <h2 className="text-base font-semibold text-ink">Región de análisis</h2>
          <button onClick={onCerrar} className="p-1 rounded hover:bg-bg text-muted" aria-label="Cerrar">
            <X size={18} />
          </button>
        </div>

        <div className="px-5 py-4 overflow-y-auto space-y-4">
          {archivos.length > 1 && (
            <label className="flex items-center gap-2 text-xs text-muted">
              Archivo de referencia
              <select
                value={indiceArchivo}
                onChange={(e) => setIndiceArchivo(Number(e.target.value))}
                className="px-2 py-1 text-sm border border-line rounded bg-surface text-ink"
              >
                {archivos.map((a, i) => (
                  <option key={a.fullPath || a.name} value={i}>
                    {a.name}
                  </option>
                ))}
              </select>
            </label>
          )}

          {cargando && <p className="text-sm text-muted">Cargando volumen…</p>}
          {error && <p className="text-sm text-danger">{error}</p>}

          {dims && bbox && (
            <>
              <p className="text-xs text-muted">
                Arrastra sobre una vista para dibujar la región. El recorte va en vóxeles y se aplica igual a todos los archivos.
              </p>
              <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
                {ORDEN_VISTAS.map((orientacion) => (
                  <VistaRecorte
                    key={orientacion}
                    nombreArchivo={nombreArchivo}
                    orientacion={orientacion}
                    dims={dims}
                    voxel={voxel}
                    bbox={bbox}
                    corte={cortes[orientacion]}
                    onCorte={(valor) => setCortes((previo) => ({ ...previo, [orientacion]: valor }))}
                    onBbox={setBbox}
                  />
                ))}
              </div>

              <div className="grid grid-cols-1 md:grid-cols-3 gap-4 pt-1">
                {['X', 'Y', 'Z'].map((nombre, eje) => (
                  <RangoEje
                    key={nombre}
                    nombre={nombre}
                    n={dims[eje]}
                    minimo={bbox[2 * eje]}
                    maximo={bbox[2 * eje + 1]}
                    onCambio={(minimo, maximo) => cambiarEje(eje, minimo, maximo)}
                  />
                ))}
              </div>
            </>
          )}
        </div>

        <div className="flex items-center justify-between gap-3 px-5 py-3 border-t border-line shrink-0">
          <p className="text-xs text-muted font-data truncate">{dims && bbox ? describirBbox(bbox) : ''}</p>
          <div className="flex items-center gap-2">
            <button
              onClick={() => dims && setBbox(bboxCompleto(dims))}
              disabled={!dims}
              className="px-3 py-1.5 text-sm rounded border border-line bg-surface text-muted hover:bg-bg disabled:opacity-50"
            >
              Volumen completo
            </button>
            <button onClick={onCerrar} className="px-3 py-1.5 text-sm rounded border border-line bg-surface text-muted hover:bg-bg">
              Cancelar
            </button>
            <Button onClick={aplicar} disabled={!dims || !bbox}>
              Aplicar región
            </Button>
          </div>
        </div>
      </div>
    </div>
  );
}
