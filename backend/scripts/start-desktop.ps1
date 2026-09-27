#!/usr/bin/env pwsh
# Script de inicio - Modo Escritorio (Windows)

Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "   MSL Process - Modo Escritorio" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Configurar modo escritorio
$env:MSL_SERVER_MODE = "desktop"

# Detectar número de threads
$numCores = (Get-WmiObject -Class Win32_Processor).NumberOfLogicalProcessors
Write-Host "CPU Cores detectados: $numCores" -ForegroundColor Green
Write-Host "Iniciando backend Julia" -ForegroundColor Yellow

# Cambiar al directorio del backend
Set-Location $PSScriptRoot\..

# Iniciar Julia con threads
julia -t $numCores server.jl