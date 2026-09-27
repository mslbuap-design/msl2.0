import { useEffect, useRef, useState } from 'react';
import { Activity, FolderOpen, FolderPlus, CheckCircle2 } from 'lucide-react';
import { useProjectContext } from '../context/ProjectContext.jsx';
import Button from './ui/Button.jsx';
import SavedProjectRow from './SavedProjectRow.jsx';
import ProjectPreviewModal from './ProjectPreviewModal.jsx';

/** @param {{backendStatus: string, backendInfo: import('../types.js').JuliaInfo | null}} props */
export default function HomeScreen({ backendStatus, backendInfo }) {
  const {
    proyectosGuardados,
    refreshProyectosGuardados,
    openPersistedProject,
    openProjectFromDialog,
    openProjectFromBrowserFileList,
    createProject,
  } = useProjectContext();

  const fileInputRef = useRef(null);
  const [previewingProject, setPreviewingProject] = useState(null);

  useEffect(() => {
    refreshProyectosGuardados();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const juliaConnected = backendStatus === 'connected';
  const triggerBrowserFallback = () => fileInputRef.current?.click();

  const handleOpenProject = () =>
    openProjectFromDialog({ juliaConnected, onFallback: triggerBrowserFallback });

  const handleCreateProject = () => createProject({ juliaConnected });

  const handleFileInputChange = (event) => {
    const fileList = Array.from(event.target.files);
    openProjectFromBrowserFileList(fileList);
  };

  return (
    <div className="flex items-center justify-center min-h-screen px-4">
      <input
        ref={fileInputRef}
        type="file"
        webkitdirectory="true"
        directory="true"
        multiple
        onChange={handleFileInputChange}
        style={{ display: 'none' }}
      />

      <div className="bg-surface rounded-xl shadow-panel border border-line p-10 max-w-lg w-full">
        <div className="flex items-center justify-center mb-4">
          <div className="w-12 h-12 rounded-lg bg-accent-50 flex items-center justify-center">
            <Activity className="text-accent" size={26} strokeWidth={2} />
          </div>
        </div>
        <h1 className="text-2xl font-semibold text-ink mb-1 text-center">MSL Process</h1>
        <p className="text-muted text-sm text-center mb-8">
          Sistema de análisis de imágenes médicas
        </p>

        {backendInfo && (
          <div className="mb-6 p-3 bg-success-50 border border-success/20 rounded-lg flex items-start gap-2">
            <CheckCircle2 className="text-success shrink-0 mt-0.5" size={16} />
            <div className="text-xs text-success">
              <p>Backend activo — Julia {backendInfo.julia_version}</p>
              {backendInfo.native_file_dialog && <p className="mt-0.5">Selector nativo disponible</p>}
            </div>
          </div>
        )}

        {proyectosGuardados.length > 0 && (
          <div className="mb-6 bg-bg rounded-lg p-4 border border-line">
            <h3 className="text-xs font-semibold text-muted mb-2">
              Gestionar proyectos
            </h3>
            <div className="space-y-1.5 max-h-56 overflow-y-auto">
              {proyectosGuardados.map((proyecto) => (
                <SavedProjectRow
                  key={proyecto.id}
                  proyecto={proyecto}
                  onOpen={() => openPersistedProject(proyecto.id)}
                  onPreview={() => setPreviewingProject(proyecto)}
                />
              ))}
            </div>
          </div>
        )}

        <div className="space-y-3">
          <Button onClick={handleOpenProject} icon={FolderOpen} fullWidth>
            Abrir proyecto
          </Button>
          <Button onClick={handleCreateProject} icon={FolderPlus} variant="secondary" fullWidth>
            Crear nuevo proyecto
          </Button>
        </div>

        <div className="mt-8 pt-5 border-t border-line">
          <p className="text-xs text-faint text-center">
            Compatible con NIfTI (.nii, .nii.gz) y DICOM
          </p>
        </div>
      </div>

      {previewingProject && (
        <ProjectPreviewModal proyecto={previewingProject} onClose={() => setPreviewingProject(null)} />
      )}
    </div>
  );
}
