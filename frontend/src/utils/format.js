/** Redondea valores numéricos a 4 decimales para mostrarlos en tablas; deja el resto tal cual. */
export function formatFeatureValue(value) {
  return typeof value === 'number' ? value.toFixed(4) : value;
}
