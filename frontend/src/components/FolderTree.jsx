import { useState } from 'react';
import { ChevronDown, ChevronRight, Folder, FileText, FileX } from 'lucide-react';
import { useProjectContext } from '../context/ProjectContext.jsx';
import { isCompatibleFile, extractAllCompatibleFiles } from '../utils/fileTree.js';

/** @typedef {import('../types.js').FileNode} FileNode */

/**
 * Árbol recursivo de carpetas/archivos. Componente compartido (no
 * pertenece a un módulo): lee la selección y la pestaña activa
 * directamente del contexto para no depender de props intermedias.
 *
 * @param {{node: FileNode, level?: number}} props
 */
export default function FolderTree({ node, level = 0 }) {
  const {
    activeTab,
    selectedFile,
    selectedFiles,
    selectFile,
    toggleFileSelection,
    toggleFolderSelection,
  } = useProjectContext();

  const [isExpanded, setIsExpanded] = useState(true);
  const showCheckboxes = ['radiomics', 'statistics', 'graphs'].includes(activeTab);

  if (node.type === 'file') {
    const compatible = isCompatibleFile(node.name, activeTab);
    const isSelected = selectedFiles.some((f) => f.path === node.path);
    const isCurrent = selectedFile?.path === node.path;

    return (
      <div
        className={`flex items-center gap-2 py-1 px-2 rounded hover:bg-bg cursor-pointer ${
          isCurrent ? 'bg-accent-50 text-accent-700 font-medium' : ''
        }`}
        style={{ paddingLeft: `${level * 18 + 20}px` }}
      >
        {showCheckboxes && (
          <input
            type="checkbox"
            checked={isSelected}
            onChange={() => toggleFileSelection(node)}
            disabled={!compatible}
            onClick={(e) => e.stopPropagation()}
            className="w-4 h-4 accent-accent"
          />
        )}
        <div
          className="flex items-center gap-2 flex-1 min-w-0"
          onClick={() => activeTab === 'visualization' && selectFile(node)}
        >
          {compatible ? (
            <FileText size={15} className="text-accent shrink-0" />
          ) : (
            <FileX size={15} className="text-faint shrink-0" />
          )}
          <span className={`text-sm truncate ${!compatible ? 'text-faint line-through' : ''}`}>
            {node.name}
          </span>
        </div>
      </div>
    );
  }

  const allFilesInFolder = extractAllCompatibleFiles(node, activeTab);
  const isFolderSelected =
    allFilesInFolder.length > 0 && allFilesInFolder.every((f) => selectedFiles.some((sf) => sf.path === f.path));

  return (
    <div>
      <div
        className={`flex items-center gap-2 py-1 px-2 rounded hover:bg-bg ${isFolderSelected ? 'bg-accent-50' : ''}`}
        style={{ paddingLeft: `${level * 18}px` }}
      >
        {showCheckboxes && (
          <input
            type="checkbox"
            checked={isFolderSelected}
            onChange={() => toggleFolderSelection(node)}
            onClick={(e) => e.stopPropagation()}
            className="w-4 h-4 accent-accent"
          />
        )}
        <div className="flex items-center gap-1.5 flex-1 cursor-pointer min-w-0" onClick={() => setIsExpanded((v) => !v)}>
          {isExpanded ? (
            <ChevronDown size={14} className="text-muted shrink-0" />
          ) : (
            <ChevronRight size={14} className="text-muted shrink-0" />
          )}
          <Folder size={15} className="text-muted shrink-0" />
          <span className="text-sm font-medium truncate">{node.name}</span>
          <span className="text-xs text-faint font-data shrink-0">({node.children?.length || 0})</span>
        </div>
      </div>
      {isExpanded && node.children && (
        <div>
          {node.children.map((child) => (
            <FolderTree key={child.path} node={child} level={level + 1} />
          ))}
        </div>
      )}
    </div>
  );
}
