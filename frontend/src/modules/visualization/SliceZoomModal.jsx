import { useCallback, useEffect, useRef, useState } from 'react';
import { Minus, Plus, RotateCcw, X } from 'lucide-react';

const MIN_ZOOM = 1;
const MAX_ZOOM = 8;
const ZOOM_STEP = 0.4;

/**
 * Visor de un corte a pantalla completa. Zoom con la rueda del mouse
 * (centrado en el cursor) o los botones +/-, y arrastre para desplazarse
 * una vez que hay zoom aplicado. Esc o el botón X para cerrar.
 */
export default function SliceZoomModal({ src, title, onClose }) {
  const [zoom, setZoom] = useState(1);
  const [pan, setPan] = useState({ x: 0, y: 0 });
  const [isDragging, setIsDragging] = useState(false);
  const containerRef = useRef(null);
  const dragStart = useRef(null);

  useEffect(() => {
    const handleKey = (e) => {
      if (e.key === 'Escape') onClose();
    };
    window.addEventListener('keydown', handleKey);
    return () => window.removeEventListener('keydown', handleKey);
  }, [onClose]);

  const clampZoom = (z) => Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, z));

  /** @param {{x: number, y: number}} [origin] Punto (relativo al centro del contenedor) que debe quedar fijo. */
  const zoomBy = useCallback((delta, origin) => {
    setZoom((prevZoom) => {
      const nextZoom = clampZoom(prevZoom + delta);
      if (nextZoom === prevZoom) return prevZoom;

      if (origin) {
        const scaleRatio = nextZoom / prevZoom;
        setPan((prevPan) => ({
          x: origin.x - (origin.x - prevPan.x) * scaleRatio,
          y: origin.y - (origin.y - prevPan.y) * scaleRatio,
        }));
      }
      if (nextZoom === MIN_ZOOM) setPan({ x: 0, y: 0 });
      return nextZoom;
    });
  }, []);

  const handleWheel = (e) => {
    e.preventDefault();
    const rect = containerRef.current.getBoundingClientRect();
    const origin = {
      x: e.clientX - rect.left - rect.width / 2,
      y: e.clientY - rect.top - rect.height / 2,
    };
    zoomBy(e.deltaY < 0 ? ZOOM_STEP : -ZOOM_STEP, origin);
  };

  const handleMouseDown = (e) => {
    if (zoom <= MIN_ZOOM) return;
    setIsDragging(true);
    dragStart.current = { x: e.clientX, y: e.clientY, panX: pan.x, panY: pan.y };
  };

  const handleMouseMove = (e) => {
    if (!dragStart.current) return;
    setPan({
      x: dragStart.current.panX + (e.clientX - dragStart.current.x),
      y: dragStart.current.panY + (e.clientY - dragStart.current.y),
    });
  };

  const stopDrag = () => {
    dragStart.current = null;
    setIsDragging(false);
  };

  const resetView = () => {
    setZoom(1);
    setPan({ x: 0, y: 0 });
  };

  return (
    <div className="fixed inset-0 z-50 bg-ink/95 flex flex-col">
      <div className="flex items-center justify-between px-5 py-3 text-white/90 shrink-0">
        <p className="text-sm font-medium">{title}</p>
        <div className="flex items-center gap-1">
          <button onClick={() => zoomBy(-ZOOM_STEP)} className="p-2 rounded hover:bg-white/10" title="Alejar">
            <Minus size={16} />
          </button>
          <span className="text-xs w-12 text-center font-data">{Math.round(zoom * 100)}%</span>
          <button onClick={() => zoomBy(ZOOM_STEP)} className="p-2 rounded hover:bg-white/10" title="Acercar">
            <Plus size={16} />
          </button>
          <button onClick={resetView} className="p-2 rounded hover:bg-white/10 ml-1" title="Restablecer">
            <RotateCcw size={16} />
          </button>
          <button onClick={onClose} className="p-2 rounded hover:bg-white/10 ml-2" title="Cerrar (Esc)">
            <X size={18} />
          </button>
        </div>
      </div>

      <div
        ref={containerRef}
        className="flex-1 min-h-0 overflow-hidden flex items-center justify-center select-none"
        onWheel={handleWheel}
        onMouseDown={handleMouseDown}
        onMouseMove={handleMouseMove}
        onMouseUp={stopDrag}
        onMouseLeave={stopDrag}
        onDoubleClick={resetView}
        style={{ cursor: zoom > MIN_ZOOM ? (isDragging ? 'grabbing' : 'grab') : 'default' }}
      >
        <img
          src={src}
          alt={title}
          draggable={false}
          className="max-h-full max-w-full object-contain"
          style={{ transform: `translate(${pan.x}px, ${pan.y}px) scale(${zoom})` }}
        />
      </div>

      <p className="text-center text-white/50 text-xs py-2.5 shrink-0">
        Rueda del mouse para zoom · arrastrar para mover · doble click para restablecer · Esc para cerrar
      </p>
    </div>
  );
}
