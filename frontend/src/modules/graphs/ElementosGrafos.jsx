import { Download } from 'lucide-react';

/** Marca de fase (sin explicaciones: el detalle vive en docs/CAMBIOS_PARA_GRAFOS.md). */
export function MarcaFase({ texto = 'Fase 2' }) {
  return (
    <span className="inline-block px-2 py-0.5 text-xs font-medium rounded bg-amber-50 border border-amber-200 text-amber-800">
      {texto}
    </span>
  );
}

/** Botón pequeño de exportación. */
export function BotonExportar({ onClick, disabled, titulo, children }) {
  return (
    <button
      onClick={onClick}
      disabled={disabled}
      title={titulo}
      className="inline-flex items-center gap-1 px-2 py-1 text-xs font-medium rounded border border-line bg-surface text-ink hover:bg-accent-50 disabled:opacity-50 disabled:cursor-not-allowed"
    >
      <Download size={12} />
      {children}
    </button>
  );
}
