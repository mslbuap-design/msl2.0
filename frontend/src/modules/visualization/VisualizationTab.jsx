import { useState } from 'react';
import { ImageOff, Loader2, Maximize2, Save } from 'lucide-react';
import { useProjectContext } from '../../context/ProjectContext.jsx';
import { useVisualization } from './useVisualization.js';
import EmptyState from '../../components/ui/EmptyState.jsx';
import SliceZoomModal from './SliceZoomModal.jsx';

const ORIENTATION_LABEL = {
  sagittal: 'Corte sagital',
  coronal: 'Corte coronal',
  axial: 'Corte axial',
};

const DIM_INDEX = { sagittal: 0, coronal: 1, axial: 2 };

function SliceViewer({ orientation, slices, imageDimensions, loadSlice, saveImage, onExpand }) {
  const slice = slices[orientation];
  const max = imageDimensions?.[DIM_INDEX[orientation]] || 1;

  return (
    <div className="h-full min-h-0 bg-bg rounded-lg p-4 flex flex-col border border-line">
      <div className="flex items-center justify-between mb-2 shrink-0">
        <h3 className="font-semibold text-ink text-sm">{ORIENTATION_LABEL[orientation]}</h3>
        <div className="flex items-center gap-2">
          <input
            type="number"
            min="1"
            max={max}
            value={slice.num}
            onChange={(e) => loadSlice(orientation, parseInt(e.target.value, 10))}
            className="w-16 px-2 py-1 border border-line rounded text-sm font-data"
          />
          <span className="text-xs text-muted font-data">/ {max}</span>
          <button
            onClick={() => onExpand(orientation)}
            disabled={!slice.image}
            className="p-1.5 bg-surface border border-line hover:bg-bg text-ink rounded transition-colors disabled:opacity-40"
            title="Ver a pantalla completa"
          >
            <Maximize2 size={14} />
          </button>
          <button
            onClick={() => saveImage(orientation, slice.num, slice.image)}
            className="p-1.5 bg-accent hover:bg-accent-600 text-white rounded transition-colors"
            title="Guardar imagen"
          >
            <Save size={14} />
          </button>
        </div>
      </div>
      <div className="flex-1 min-h-0 flex items-center justify-center bg-ink rounded overflow-hidden">
        {slice.image ? (
          <img
            src={slice.image}
            alt={ORIENTATION_LABEL[orientation]}
            className="w-full h-full object-contain cursor-zoom-in"
            onClick={() => onExpand(orientation)}
          />
        ) : (
          <p className="text-faint text-sm">Cargando...</p>
        )}
      </div>
    </div>
  );
}

export default function VisualizationTab() {
  const { project } = useProjectContext();
  const { selectedFile, imageLoaded, imageDimensions, slices, loadSlice, saveImage } = useVisualization();
  const [expandedOrientation, setExpandedOrientation] = useState(null);

  if (!selectedFile) {
    return <EmptyState icon={ImageOff} title="Selecciona un archivo del árbol" />;
  }

  if (!imageLoaded) {
    return (
      <div className="flex flex-col items-center justify-center h-full">
        <Loader2 className="text-accent animate-spin mb-4" size={40} />
        <p className="text-muted text-sm">Cargando imagen...</p>
      </div>
    );
  }

  const viewerProps = { slices, imageDimensions, loadSlice, saveImage, onExpand: setExpandedOrientation };

  return (
    <div className="grid grid-cols-2 grid-rows-2 gap-4 h-full min-h-0">
      <SliceViewer orientation="sagittal" {...viewerProps} />
      <SliceViewer orientation="coronal" {...viewerProps} />

      <div className="h-full min-h-0 bg-bg rounded-lg p-4 flex flex-col border border-line">
        <h3 className="font-semibold text-ink text-sm mb-3">Información</h3>
        <div className="space-y-2 text-sm">
          <div className="flex justify-between gap-2">
            <span className="text-muted">Archivo</span>
            <span className="font-medium text-ink truncate font-data">{selectedFile?.name}</span>
          </div>
          <div className="flex justify-between gap-2">
            <span className="text-muted">Dimensiones</span>
            <span className="font-medium text-ink font-data">{imageDimensions?.join(' × ')}</span>
          </div>
          {project?.ruta && (
            <div className="mt-4 pt-4 border-t border-line">
              <span className="text-muted text-xs">Proyecto</span>
              <p className="font-medium text-ink text-xs mt-1 break-all font-data">{project.ruta}</p>
            </div>
          )}
        </div>
      </div>

      <SliceViewer orientation="axial" {...viewerProps} />

      {expandedOrientation && (
        <SliceZoomModal
          src={slices[expandedOrientation].image}
          title={ORIENTATION_LABEL[expandedOrientation]}
          onClose={() => setExpandedOrientation(null)}
        />
      )}
    </div>
  );
}
