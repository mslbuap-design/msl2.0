/** Estado vacío/placeholder genérico usado dentro de cada panel de resultados. */
export default function EmptyState({ icon: Icon, title, description }) {
  return (
    <div className="flex flex-1 flex-col items-center justify-center text-center px-6">
      {Icon && <Icon className="text-faint mb-3" size={40} strokeWidth={1.5} />}
      <p className="text-ink text-base font-medium mb-1">{title}</p>
      {description && <p className="text-muted text-sm max-w-sm">{description}</p>}
    </div>
  );
}
