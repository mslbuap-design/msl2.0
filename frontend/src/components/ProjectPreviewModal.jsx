import { useEffect, useState } from 'react';
import { AlertCircle, Check, Folder, Loader2, Pencil, X } from 'lucide-react';
import * as api from '../services/api.js';

/** @param {{proyecto: {id: number, nombre: string, ruta_base: string}, onClose: () => void}} props */
export default function ProjectPreviewModal({ proyecto, onClose }) {
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(null);
  const [structure, setStructure] = useState(null);
  const [renamingPath, setRenamingPath] = useState(null);
  const [renameValue, setRenameValue] = useState('');
  const [savingRename, setSavingRename] = useState(false);

  const cargarEstructura = async () => {
    setLoading(true);
    setError(null);
    try {
      const data = await api.abrirProyectoPersistente(proyecto.id);
      if (data.success) {
        setStructure(data.estructura);
      } else {
        setError(data.error || 'No se pudo cargar el proyecto');
      }
    } catch (e) {
      console.error(e);
      setError('Error de conexión con el servidor');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    cargarEstructura();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [proyecto.id]);

  const grupos = (structure?.children || []).filter((child) => child.type === 'folder');

  const startRename = (folder) => {
    setRenamingPath(folder.path);
    setRenameValue(folder.name);
  };

  const confirmRename = async (folder) => {
    const nuevoNombre = renameValue.trim();
    if (!nuevoNombre || nuevoNombre === folder.name) {
      setRenamingPath(null);
      return;
    }
    setSavingRename(true);
    try {
      const result = await api.renombrarCarpetaProyecto(proyecto.id, folder.path, nuevoNombre);
      if (result.success) {
        setRenamingPath(null);
        await cargarEstructura();
      } else {
        window.alert(`❌ ${result.error || 'No se pudo renombrar la carpeta'}`);
      }
    } catch (e) {
      console.error(e);
      window.alert('❌ Error renombrando la carpeta (¿el backend ya tiene este endpoint?)');
    } finally {
      setSavingRename(false);
    }
  };

  return (
    <div className="fixed inset-0 z-50 bg-ink/40 flex items-center justify-center p-4">
      <div className="bg-surface rounded-xl shadow-overlay border border-line w-full max-w-md flex flex-col max-h-[80vh]">
        <div className="flex items-center justify-between px-5 py-4 border-b border-line shrink-0">
          <div className="min-w-0">
            <h2 className="text-base font-semibold text-ink truncate">{proyecto.nombre}</h2>
            <p className="text-xs text-muted truncate font-data">{proyecto.ruta_base}</p>
          </div>
          <button onClick={onClose} className="p-1 rounded hover:bg-bg text-muted shrink-0 ml-2">
            <X size={18} />
          </button>
        </div>

        <div className="px-5 py-4 overflow-y-auto">
          {loading && (
            <div className="flex items-center justify-center py-8">
              <Loader2 className="text-accent animate-spin" size={28} />
            </div>
          )}

          {!loading && error && (
            <div className="flex items-start gap-2 bg-danger-50 border border-danger/20 rounded-lg p-3">
              <AlertCircle size={16} className="text-danger shrink-0 mt-0.5" />
              <p className="text-sm text-danger">{error}</p>
            </div>
          )}

          {!loading && !error && (
            <>
              <p className="text-xs font-medium text-muted mb-2">Grupos ({grupos.length})</p>
              {grupos.length === 0 && (
                <p className="text-sm text-faint py-3 text-center">Este proyecto todavía no tiene carpetas.</p>
              )}
              <div className="space-y-1">
                {grupos.map((folder) => (
                  <div key={folder.path} className="flex items-center gap-2 px-3 py-2 rounded-lg border border-line">
                    <Folder size={15} className="text-muted shrink-0" />
                    {renamingPath === folder.path ? (
                      <>
                        <input
                          autoFocus
                          type="text"
                          value={renameValue}
                          onChange={(e) => setRenameValue(e.target.value)}
                          onKeyDown={(e) => {
                            if (e.key === 'Enter') confirmRename(folder);
                            if (e.key === 'Escape') setRenamingPath(null);
                          }}
                          className="flex-1 min-w-0 px-2 py-1 border border-line rounded text-sm"
                        />
                        <button
                          onClick={() => confirmRename(folder)}
                          disabled={savingRename}
                          className="text-success shrink-0"
                          title="Confirmar"
                        >
                          <Check size={16} />
                        </button>
                        <button onClick={() => setRenamingPath(null)} className="text-faint shrink-0" title="Cancelar">
                          <X size={16} />
                        </button>
                      </>
                    ) : (
                      <>
                        <span className="text-sm text-ink flex-1 truncate">{folder.name}</span>
                        <span className="text-xs text-faint font-data shrink-0">
                          {folder.children?.length || 0}
                        </span>
                        <button
                          onClick={() => startRename(folder)}
                          className="text-muted hover:text-accent shrink-0"
                          title="Renombrar carpeta"
                        >
                          <Pencil size={14} />
                        </button>
                      </>
                    )}
                  </div>
                ))}
              </div>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
