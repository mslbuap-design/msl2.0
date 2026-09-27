import { useProjectContext } from './context/ProjectContext.jsx';
import { useBackendStatus } from './hooks/useBackendStatus.js';
import ConnectionStatus from './components/ConnectionStatus.jsx';
import LoadingOverlay from './components/LoadingOverlay.jsx';
import HomeScreen from './components/HomeScreen.jsx';
import WorkspaceScreen from './components/WorkspaceScreen.jsx';

export default function App() {
  const { hasProject, busy, busyMessage } = useProjectContext();
  const { status: backendStatus, info: backendInfo, recheck } = useBackendStatus();

  return (
    <div className="min-h-screen bg-bg">
      {busy && <LoadingOverlay message={busyMessage} />}

      <ConnectionStatus status={backendStatus} onClick={recheck} />

      {hasProject ? (
        <WorkspaceScreen />
      ) : (
        <HomeScreen backendStatus={backendStatus} backendInfo={backendInfo} />
      )}
    </div>
  );
}
