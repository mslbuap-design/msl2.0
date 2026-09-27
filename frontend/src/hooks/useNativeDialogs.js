/**
 * Envoltorio delgado sobre `window.prompt`/`window.alert`.
 *
 * La app original usa diálogos nativos del navegador para pedir nombres de
 * proyecto, carpetas destino, etc. Se conserva ese comportamiento tal cual
 * (misma información pedida, mismo orden) para no cambiar la funcionalidad,
 * pero aislado aquí: el día que se reemplacen por modales propios, solo hay
 * que reescribir estas tres funciones — ningún módulo que las use cambia.
 */
export function useNativeDialogs() {
  const promptText = (message, defaultValue = '') => window.prompt(message, defaultValue);
  const notify = (message) => window.alert(message);
  const confirmAction = (message) => window.confirm(message);

  return { promptText, notify, confirmAction };
}
