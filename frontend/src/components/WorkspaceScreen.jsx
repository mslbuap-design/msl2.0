import { CheckSquare, Square, Eye, FlaskConical, BarChart3 } from 'lucide-react';
import { useProjectContext } from '../context/ProjectContext.jsx';
import { extractAllCompatibleFiles } from '../utils/fileTree.js';
import WorkspaceHeader from './WorkspaceHeader.jsx';
import FolderTree from './FolderTree.jsx';
import TabBar from './TabBar.jsx';
import VisualizationTab from '../modules/visualization/VisualizationTab.jsx';
import RadiomicsTab from '../modules/radiomics/RadiomicsTab.jsx';
import StatisticsTab from '../modules/statistics/StatisticsTab.jsx';

const TABS = [
  { id: 'visualization', label: 'Visualización', icon: Eye },
  { id: 'radiomics', label: 'Radiómica', icon: FlaskConical },
  { id: 'statistics', label: 'Estadísticas', icon: BarChart3 },
  // Grafos: reservado — ver modules/graphs/. Se agrega aquí cuando se implemente.
];

export default function WorkspaceScreen() {
  const { structure, activeTab, changeTab, selectedFiles, selectAllCompatible } = useProjectContext();

  const showSelectAll = (activeTab === 'radiomics' || activeTab === 'statistics') && structure;
  const allCompatible = structure ? extractAllCompatibleFiles(structure, activeTab) : [];
  const allSelected = showSelectAll && selectedFiles.length === allCompatible.length && allCompatible.length > 0;

  return (
    <div className="min-h-screen p-6">
      <WorkspaceHeader />

      <div className="flex gap-6 h-[calc(100vh-120px)] min-h-0">
        <aside className="w-64 min-h-0 bg-surface rounded-xl border border-line p-4 overflow-y-auto">
          <div className="flex items-center justify-between mb-3">
            <h3 className="text-xs font-semibold text-muted">
              Estructura del proyecto
            </h3>
            {showSelectAll && (
              <button
                onClick={selectAllCompatible}
                className="flex items-center gap-1 text-xs text-accent hover:text-accent-700 font-medium"
                title="Marcar/Desmarcar todo"
              >
                {allSelected ? <CheckSquare size={13} /> : <Square size={13} />}
                Todo
              </button>
            )}
          </div>

          {structure ? (
            <FolderTree node={structure} />
          ) : (
            <p className="text-xs text-faint text-center mt-8">Cargando estructura...</p>
          )}
        </aside>

        <main className="flex-1 min-h-0 bg-surface rounded-xl border border-line overflow-hidden flex flex-col">
          <TabBar tabs={TABS} activeTab={activeTab} onChange={changeTab} />

          <div className="p-6 flex-1 min-h-0 overflow-y-auto">
            <div className={activeTab === 'visualization' ? 'h-full min-h-0' : 'hidden'}>
              <VisualizationTab />
            </div>
            <div className={activeTab === 'radiomics' ? 'h-full min-h-0' : 'hidden'}>
              <RadiomicsTab />
            </div>
            <div className={activeTab === 'statistics' ? 'h-full min-h-0' : 'hidden'}>
              <StatisticsTab />
            </div>
          </div>
        </main>
      </div>
    </div>
  );
}
