import { Network } from 'lucide-react';
import EmptyState from '../../components/ui/EmptyState.jsx';

/**
 * Carpeta reservada para el módulo de Grafos. No está conectada al TabBar
 * todavía — agregarla más adelante es: (1) sumar una entrada a la lista de
 * tabs en App.jsx, (2) renderizar <GraphsTab /> junto a los otros paneles.
 * Ningún módulo existente necesita tocarse para eso.
 */
export default function GraphsTab() {
  return (
    <EmptyState
      icon={Network}
      title="Módulo de Grafos"
      description="Próximamente: análisis por grafos. Esta pestaña está reservada en la arquitectura pero aún no implementada."
    />
  );
}
