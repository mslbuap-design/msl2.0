#!/bin/bash
# Script de inicio - Modo Escritorio (Linux/Mac)

echo "═══════════════════════════════════════════════"
echo "   MSL Process - Modo Escritorio"
echo "═══════════════════════════════════════════════"
echo ""

# Configurar modo escritorio
export MSL_SERVER_MODE="desktop"

# Detectar número de cores
NUM_CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu)
echo "🧵 CPU Cores detectados: $NUM_CORES"
echo "🔷 Iniciando backend Julia..."
echo ""

# Cambiar al directorio del backend
cd "$(dirname "$0")/.."

# Iniciar Julia con threads
julia -t $NUM_CORES server.jl