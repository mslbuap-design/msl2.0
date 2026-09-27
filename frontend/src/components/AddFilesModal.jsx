import { useMemo, useState } from 'react';
import { AlertCircle, ChevronDown, ChevronRight, Folder, FolderPlus, Upload, X } from 'lucide-react';
import { useProjectContext } from '../context/ProjectContext.jsx';
import { relativeToProjectRoot } from '../utils/fileTree.js';
import Button from './ui/Button.jsx';

/** @typedef {import('../types.js').FileNode} FileNode */

/** Árbol de solo-carpetas, de selección única — independiente de la selección del sidebar. */
function FolderPickerTree({ node, level = 0, selectedPath, onSelect }) {
  const [expanded, setExpanded] = useState(true);
  const subfolders = (node.children || []).filter((child) => child.type === 'folder');
  const isSelected = selectedPath === node.path;

  return (
    <div>
      <div
        className={`flex items-center gap-1.5 py-1.5 px-2 rounded cursor-pointer ${
          isSelected ? 'bg-accent-50 text-accent-700 font-medium' : 'hover:bg-bg'
        }`}
        style={{ paddingLeft: `${level * 18 + 4}px` }}
        onClick={() => onSelect(node)}
      >
        <button
          onClick={(e) => {
            e.stopPropagation();
            setExpanded((v) => !v);
          }}
          className="shrink-0 text-muted"
        >
          {subfolders.length > 0 ? (
            expanded ? <ChevronDown size={13} /> : <ChevronRight size={13} />
          ) : (
            <span className="inline-block w-[13px]" />
          )}
        </button>
        <Folder size={14} className="shrink-0" />
        <span className="text-sm truncate">{node.name}</span>
      </div>
      {expanded &&
        subfolders.map((child) => (
          <FolderPickerTree key={child.path} node={child} level={level + 1} selectedPath={selectedPath} onSelect={onSelect} />
        ))}
    </div>
  );
}

/** @param {{files: File[], onClose: () => void}} props */
export default function AddFilesModal({ files, onClose }) {
  const { structure, addFiles, addGroups } = useProjectContext();

  const [pendingFiles, setPendingFiles] = useState(files);
  const [selectedFolder, setSelectedFolder] = useState(null);
  const [nombreBase, setNombreBase] = useState('Archivo');

  const topLevelFolders = useMemo(
    () => (structure?.children || []).filter((child) => child.type === 'folder'),
    [structure]
  );
  const hasFolders = topLevelFolders.length > 0;

  const removeFile = (idx) => {
    setPendingFiles((prev) => prev.filter((_, i) => i !== idx));
  };

  const handleConfirm = () => {
    if (pendingFiles.length === 0 || !selectedFolder || !nombreBase.trim()) return;
    const carpetaDestino = relativeToProjectRoot(selectedFolder.path, structure.name);
    onClose();
    addFiles({ fileList: pendingFiles, carpetaDestino, nombreBase: nombreBase.trim() });
  };

  const handleCreateGroupInstead = () => {
    onClose();
    addGroups();
  };

  const canConfirm = pendingFiles.length > 0 && !!selectedFolder && nombreBase.trim().length > 0;

  return (
    <div className="fixed inset-0 z-50 bg-ink/40 flex items-center justify-center p-4">
      <div className="bg-surface rounded-xl shadow-overlay border border-line w-full max-w-lg flex flex-col max-h-[85vh]">
        <div className="flex items-center justify-between px-5 py-4 border-b border-line shrink-0">
          <h2 className="text-base font-semibold text-ink">Agregar archivos</h2>
          <button onClick={onClose} className="p-1 rounded hover:bg-bg text-muted">
            <X size={18} />
          </button>
        </div>

        <div className="px-5 py-4 space-y-5 overflow-y-auto">
          {/* Archivos pendientes */}
          <div>
            <p className="text-xs font-medium text-muted mb-2">
              Archivos seleccionados ({pendingFiles.length})
            </p>
            <div className="border border-line rounded-lg max-h-32 overflow-y-auto divide-y divide-line">
              {pendingFiles.map((file, idx) => (
                <div key={`${file.name}-${idx}`} className="flex items-center justify-between gap-2 px-3 py-1.5">
                  <span className="text-sm text-ink truncate">{file.name}</span>
                  <button onClick={() => removeFile(idx)} className="text-faint hover:text-danger shrink-0" title="Quitar">
                    <X size={14} />
                  </button>
                </div>
              ))}
              {pendingFiles.length === 0 && (
                <p className="text-xs text-faint text-center py-3">No quedan archivos por subir</p>
              )}
            </div>
          </div>

          {/* Carpeta destino */}
          <div>
            <p className="text-xs font-medium text-muted mb-2">Carpeta destino</p>
            {hasFolders ? (
              <div className="border border-line rounded-lg max-h-44 overflow-y-auto p-1">
                {topLevelFolders.map((folder) => (
                  <FolderPickerTree
                    key={folder.path}
                    node={folder}
                    selectedPath={selectedFolder?.path}
                    onSelect={setSelectedFolder}
                  />
                ))}
              </div>
            ) : (
              <div className="border border-line rounded-lg p-3 flex items-start gap-2 bg-warning-50">
                <AlertCircle size={16} className="text-warning shrink-0 mt-0.5" />
                <div className="flex-1">
                  <p className="text-xs text-warning">Este proyecto todavía no tiene carpetas.</p>
                  <button
                    onClick={handleCreateGroupInstead}
                    className="mt-1.5 inline-flex items-center gap-1 text-xs font-medium text-accent hover:text-accent-700"
                  >
                    <FolderPlus size={12} />
                    Crear un grupo primero
                  </button>
                </div>
              </div>
            )}
          </div>

          {/* Nombre base */}
          <div>
            <label className="text-xs font-medium text-muted mb-2 block">Nombre base para los archivos</label>
            <input
              type="text"
              value={nombreBase}
              onChange={(e) => setNombreBase(e.target.value)}
              placeholder="Archivo"
              className="w-full px-3 py-2 border border-line rounded-lg text-sm"
            />
          </div>
        </div>

        <div className="flex items-center justify-end gap-2 px-5 py-4 border-t border-line shrink-0">
          <Button onClick={onClose} variant="secondary">
            Cancelar
          </Button>
          <Button onClick={handleConfirm} disabled={!canConfirm} icon={Upload}>
            Confirmar y subir
          </Button>
        </div>
      </div>
    </div>
  );
}
