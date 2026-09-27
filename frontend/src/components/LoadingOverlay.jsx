import { Loader2 } from 'lucide-react';

/** @param {{message: string}} props */
export default function LoadingOverlay({ message }) {
  return (
    <div className="fixed inset-0 bg-ink/40 z-50 flex items-center justify-center px-4">
      <div className="bg-surface rounded-xl p-8 max-w-sm w-full shadow-overlay border border-line">
        <div className="text-center">
          <Loader2 className="text-accent mx-auto mb-4 animate-spin" size={40} strokeWidth={2} />
          <h2 className="text-lg font-semibold text-ink mb-1">Procesando</h2>
          <p className="text-muted text-sm">{message}</p>
        </div>
      </div>
    </div>
  );
}
