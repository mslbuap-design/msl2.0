const STATUS_STYLES = {
  connected: 'bg-success',
  checking: 'bg-warning animate-pulse',
  disconnected: 'bg-danger',
};

const STATUS_LABEL = {
  connected: 'Julia: conectado',
  checking: 'Julia: verificando...',
  disconnected: 'Julia: desconectado',
};

/** @param {{status: 'connected'|'checking'|'disconnected', onClick: () => void}} props */
export default function ConnectionStatus({ status, onClick }) {
  return (
    <button
      onClick={onClick}
      title={STATUS_LABEL[status]}
      className="fixed top-4 right-4 z-40 flex items-center gap-2 rounded-full bg-surface/90 backdrop-blur
        border border-line px-3 py-1.5 shadow-panel"
    >
      <span className={`w-2 h-2 rounded-full ${STATUS_STYLES[status]}`} />
      <span className="text-xs font-medium text-muted">{STATUS_LABEL[status]}</span>
    </button>
  );
}
