import { useRef, useState } from 'react';
import { AlertTriangle, ArrowLeft, Upload, Plus } from 'lucide-react';
import { useProjectContext } from '../context/ProjectContext.jsx';
import Button from './ui/Button.jsx';
import AddFilesModal from './AddFilesModal.jsx';

export default function WorkspaceHeader() {
  const { project, goHome, addGroups } = useProjectContext();
  const addFilesInputRef = useRef(null);
  const [pendingFiles, setPendingFiles] = useState(null); // null = modal cerrado

  const handleAddFilesClick = () => {
    if (!project?.ruta) {
      window.alert(
        '⚠️  No se puede determinar la ruta real de este proyecto (se abrió con el selector del navegador, ' +
        'sin selector nativo disponible). "Agregar archivos" no está disponible hasta reabrirlo de otra forma.'
      );
      return;
    }
    addFilesInputRef.current?.click();
  };

  const handleAddFilesChange = (event) => {
    const fileList = Array.from(event.target.files);
    event.target.value = '';
    if (fileList.length > 0) setPendingFiles(fileList);
  };

  return (
    <div className="mb-6 flex flex-wrap items-center justify-between gap-3">
      <input
        ref={addFilesInputRef}
        type="file"
        multiple
        onChange={handleAddFilesChange}
        style={{ display: 'none' }}
      />

      <Button onClick={goHome} variant="secondary" icon={ArrowLeft}>
        Volver
      </Button>

      <div className="flex items-center gap-3">
        {project?.ruta ? (
          <div className="bg-surface px-4 py-2 rounded-lg border border-line">
            <p className="text-xs text-muted">Proyecto</p>
            <p className="text-sm font-medium text-ink truncate max-w-xs font-data">{project.ruta}</p>
          </div>
        ) : (
          <div className="bg-warning-50 px-3 py-2 rounded-lg border border-warning/30 flex items-center gap-2 max-w-xs">
            <AlertTriangle size={14} className="text-warning shrink-0" />
            <p className="text-xs text-warning">
              Ruta desconocida — agregar archivos/grupos no disponible
            </p>
          </div>
        )}

        <Button onClick={handleAddFilesClick} icon={Upload} variant="subtle">
          Agregar archivos
        </Button>

        <Button onClick={addGroups} icon={Plus} variant="subtle">
          Agregar grupos
        </Button>
      </div>

      {pendingFiles && (
        <AddFilesModal files={pendingFiles} onClose={() => setPendingFiles(null)} />
      )}
    </div>
  );
}
