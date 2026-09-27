import { useState } from 'react';
import { Check, Eye, Folder, Pencil, Trash2, X } from 'lucide-react';
import { useProjectContext } from '../context/ProjectContext.jsx';

/** @param {{proyecto: {id: number, nombre: string, ruta_base: string}, onOpen: () => void, onPreview: () => void}} props */
export default function SavedProjectRow({ proyecto, onOpen, onPreview }) {
  const { renombrarProyecto, eliminarProyecto } = useProjectContext();
  const [mode, setMode] = useState('normal'); // 'normal' | 'renaming' | 'confirming-delete'
  const [nombreValue, setNombreValue] = useState(proyecto.nombre);
  const [busy, setBusy] = useState(false);

  const stop = (e) => e.stopPropagation();

  const confirmRename = async () => {
    const nuevo = nombreValue.trim();
    if (!nuevo || nuevo === proyecto.nombre) {
      setMode('normal');
      return;
    }
    setBusy(true);
    await renombrarProyecto(proyecto.id, nuevo);
    setBusy(false);
    setMode('normal');
  };

  const confirmDelete = async () => {
    setBusy(true);
    await eliminarProyecto(proyecto.id);
    setBusy(false);
    // si falló, el aviso ya lo mostró el contexto — solo volvemos a modo normal
    setMode('normal');
  };

  if (mode === 'renaming') {
    return (
      <div className="w-full bg-surface rounded border border-accent/40 px-3 py-2 flex items-center gap-2">
        <Folder size={14} className="text-muted shrink-0" />
        <input
          autoFocus
          type="text"
          value={nombreValue}
          onChange={(e) => setNombreValue(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') confirmRename();
            if (e.key === 'Escape') setMode('normal');
          }}
          className="flex-1 min-w-0 px-1.5 py-0.5 border border-line rounded text-sm"
        />
        <button onClick={confirmRename} disabled={busy} className="text-success shrink-0" title="Confirmar">
          <Check size={15} />
        </button>
        <button onClick={() => setMode('normal')} className="text-faint shrink-0" title="Cancelar">
          <X size={15} />
        </button>
      </div>
    );
  }

  if (mode === 'confirming-delete') {
    return (
      <div className="w-full bg-danger-50 rounded border border-danger/30 px-3 py-2 flex items-center justify-between gap-2">
        <span className="text-xs text-danger truncate">¿Eliminar "{proyecto.nombre}"?</span>
        <div className="flex items-center gap-2 shrink-0">
          <button
            onClick={confirmDelete}
            disabled={busy}
            className="text-xs font-medium text-danger hover:text-danger/80"
          >
            Sí, eliminar
          </button>
          <button onClick={() => setMode('normal')} className="text-xs text-muted hover:text-ink">
            Cancelar
          </button>
        </div>
      </div>
    );
  }

  return (
    <div
      className="w-full bg-surface rounded border border-line px-3 py-2 hover:border-accent/40 hover:bg-accent-50/40
        transition-colors flex items-center gap-2 cursor-pointer"
      onClick={onOpen}
    >
      <Folder size={14} className="text-muted shrink-0" />
      <div className="min-w-0 flex-1">
        <div className="font-medium text-ink text-sm truncate">{proyecto.nombre}</div>
        <div className="text-xs text-muted truncate font-data">{proyecto.ruta_base}</div>
      </div>
      <div className="flex items-center gap-1 shrink-0">
        <button
          onClick={(e) => { stop(e); onPreview(); }}
          className="p-1.5 rounded text-muted hover:text-accent hover:bg-accent-50"
          title="Vista previa"
        >
          <Eye size={14} />
        </button>
        <button
          onClick={(e) => { stop(e); setMode('renaming'); }}
          className="p-1.5 rounded text-muted hover:text-accent hover:bg-accent-50"
          title="Editar nombre"
        >
          <Pencil size={14} />
        </button>
        <button
          onClick={(e) => { stop(e); setMode('confirming-delete'); }}
          className="p-1.5 rounded text-muted hover:text-danger hover:bg-danger-50"
          title="Eliminar proyecto"
        >
          <Trash2 size={14} />
        </button>
      </div>
    </div>
  );
}
