import { useEffect, useState } from 'react';
import { ChevronLeft, ChevronRight } from 'lucide-react';
import * as api from '../../services/api.js';
import { VISTAS, aspectoVista, totalCortes } from './graphUtils.js';

const ORDEN_VISTAS = ['axial', 'coronal', 'sagittal'];

const LEYENDA = [
  { color: 'bg-sky-500', texto: 'Máscara' },
  { color: 'bg-red-500', texto: 'Esqueleto' },
  { color: 'bg-yellow-400', texto: 'Bifurcaciones' },
  { color: 'bg-cyan-400', texto: 'Puntas' },
];

/**
 * Visor de cortes de un resultado ya analizado: el volumen con la máscara, el
 * esqueleto y los nodos superpuestos, en las 3 orientaciones y con navegación
 * entre cortes. Cada corte lo dibuja el backend a partir de lo que dejó el
 * análisis en memoria (`POST /api/grafos/corte`), sin recalcular nada.
 *
 * @param {{resultadoId: string, dimensiones: number[], voxelDims: number[]}} props
 */
export default function VisorCortes({ resultadoId, dimensiones, voxelDims }) {
  const [orientacion, setOrientacion] = useState('axial');
  const [indices, setIndices] = useState(() => ({
    axial: Math.ceil(dimensiones[2] / 2),
    coronal: Math.ceil(dimensiones[1] / 2),
    sagittal: Math.ceil(dimensiones[0] / 2),
  }));
  const [capas, setCapas] = useState({ mascara: true, esqueleto: true, nodos: true });
  const [grosor, setGrosor] = useState(3);
  const [imagen, setImagen] = useState(null);
  const [error, setError] = useState(null);

  const total = totalCortes(orientacion, dimensiones);
  const indice = indices[orientacion];

  const irACorte = (valor) => {
    const v = Math.min(total, Math.max(1, valor));
    setIndices((previo) => ({ ...previo, [orientacion]: v }));
  };

  useEffect(() => {
    let cancelado = false;
    const temporizador = setTimeout(async () => {
      try {
        const r = await api.grafosCorte({ resultado_id: resultadoId, orientacion, indice, capas, grosor });
        if (cancelado) return;
        if (r.success) {
          setImagen(r.imagen);
          setError(null);
        } else {
          setError(r.error || 'No se pudo obtener el corte');
        }
      } catch {
        if (!cancelado) setError('Error de conexión');
      }
    }, 80);
    return () => {
      cancelado = true;
      clearTimeout(temporizador);
    };
  }, [resultadoId, orientacion, indice, capas, grosor]);

  const alternarCapa = (clave) => setCapas((previo) => ({ ...previo, [clave]: !previo[clave] }));

  return (
    <div className="flex flex-wrap gap-4 items-start">
      <div className="flex-1 min-w-[240px] max-w-xl">
        <div
          className="relative bg-black rounded border border-line overflow-hidden"
          style={{ aspectRatio: String(aspectoVista(orientacion, dimensiones, voxelDims)) }}
        >
          {imagen && (
            <img
              src={imagen}
              alt={`Corte ${VISTAS[orientacion].nombre} ${indice}`}
              className="absolute inset-0 w-full h-full"
            />
          )}
        </div>
        {error && <p className="text-xs text-danger mt-1">{error}</p>}
        <div className="flex flex-wrap gap-x-3 gap-y-1 mt-2">
          {LEYENDA.map(({ color, texto }) => (
            <span key={texto} className="inline-flex items-center gap-1.5 text-xs text-muted">
              <span className={`inline-block w-2.5 h-2.5 rounded-sm ${color}`} />
              {texto}
            </span>
          ))}
        </div>
      </div>

      <div className="w-56 space-y-3 text-sm">
        <div className="flex rounded border border-line overflow-hidden">
          {ORDEN_VISTAS.map((o) => (
            <button
              key={o}
              onClick={() => setOrientacion(o)}
              className={`flex-1 px-2 py-1.5 text-xs font-medium ${
                orientacion === o ? 'bg-accent text-white' : 'bg-surface text-muted hover:bg-bg'
              }`}
            >
              {VISTAS[o].nombre}
            </button>
          ))}
        </div>

        <div>
          <div className="flex items-center justify-between text-xs text-muted mb-1">
            <span>Corte</span>
            <span className="font-data text-ink">
              {indice} / {total}
            </span>
          </div>
          <div className="flex items-center gap-1.5">
            <button
              onClick={() => irACorte(indice - 1)}
              disabled={indice <= 1}
              className="p-1 rounded border border-line bg-surface text-muted hover:bg-bg disabled:opacity-40"
              aria-label="Corte anterior"
            >
              <ChevronLeft size={14} />
            </button>
            <input
              type="range"
              min={1}
              max={total}
              value={indice}
              onChange={(e) => irACorte(Number(e.target.value))}
              aria-label="Corte"
              className="flex-1 accent-accent"
            />
            <button
              onClick={() => irACorte(indice + 1)}
              disabled={indice >= total}
              className="p-1 rounded border border-line bg-surface text-muted hover:bg-bg disabled:opacity-40"
              aria-label="Corte siguiente"
            >
              <ChevronRight size={14} />
            </button>
          </div>
        </div>

        <div className="space-y-1.5">
          {[
            ['mascara', 'Máscara'],
            ['esqueleto', 'Esqueleto'],
            ['nodos', 'Nodos'],
          ].map(([clave, etiqueta]) => (
            <label key={clave} className="flex items-center gap-2 text-xs text-muted cursor-pointer">
              <input
                type="checkbox"
                checked={capas[clave]}
                onChange={() => alternarCapa(clave)}
                className="w-3.5 h-3.5 accent-accent"
              />
              {etiqueta}
            </label>
          ))}
        </div>

        <div title="El esqueleto y los nodos de los cortes vecinos (a cada lado) se proyectan sobre este corte.">
          <div className="flex items-center justify-between text-xs text-muted mb-1">
            <span>Grosor del esqueleto</span>
            <span className="font-data text-ink">±{grosor}</span>
          </div>
          <input
            type="range"
            min={0}
            max={10}
            value={grosor}
            onChange={(e) => setGrosor(Number(e.target.value))}
            aria-label="Grosor del esqueleto"
            className="w-full accent-accent"
          />
        </div>
      </div>
    </div>
  );
}
