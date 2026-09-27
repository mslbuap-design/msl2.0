#!/usr/bin/env node

const { spawn } = require('child_process');
const http = require('http');
const path = require('path');
const fs = require('fs');
const os = require('os');

console.log('═══════════════════════════════════════════════');
console.log('    🖥️  MSL Process - Modo Escritorio');
console.log('═══════════════════════════════════════════════\n');

const JULIA_PORT = 8000;
const FRONTEND_PORT = 3000;
const BACKEND_DIR = path.join(__dirname, '..', 'backend');
const FRONTEND_DIR = path.join(__dirname, '..', 'frontend', 'build');

// Detectar sistema operativo
const isWindows = os.platform() === 'win32';

// Detectar número de cores
const numCores = os.cpus().length;
console.log(`🧵 CPU Cores detectados: ${numCores}`);
console.log(`💻 Sistema operativo: ${os.platform()}\n`);

// 1. Verificar que los directorios existan
if (!fs.existsSync(BACKEND_DIR)) {
    console.error('❌ Error: No se encontró el directorio backend');
    console.error(`   Buscado en: ${BACKEND_DIR}`);
    process.exit(1);
}

if (!fs.existsSync(FRONTEND_DIR)) {
    console.error('❌ Error: No se encontró el frontend compilado');
    console.error(`   Buscado en: ${FRONTEND_DIR}`);
    console.error('\n💡 Solución:');
    console.error('   1. cd frontend');
    console.error('   2. npm install');
    console.error('   3. npm run build');
    process.exit(1);
}

// 2. Iniciar servidor Julia
console.log('🔷 Iniciando servidor Julia (modo escritorio)...');

const startScript = isWindows 
    ? path.join(BACKEND_DIR, 'scripts', 'start-desktop.ps1')
    : path.join(BACKEND_DIR, 'scripts', 'start-desktop.sh');

const juliaProcess = spawn(
    isWindows ? 'powershell' : 'bash',
    isWindows ? ['-File', startScript] : [startScript],
    {
        cwd: BACKEND_DIR,
        stdio: ['ignore', 'pipe', 'pipe'],
        env: { ...process.env, MSL_SERVER_MODE: 'desktop' }
    }
);

juliaProcess.stdout.on('data', (data) => {
    console.log(`[Julia] ${data.toString().trim()}`);
});

juliaProcess.stderr.on('data', (data) => {
    console.error(`[Julia Error] ${data.toString().trim()}`);
});

juliaProcess.on('close', (code) => {
    console.log(`\n❌ Servidor Julia cerrado con código ${code}`);
    process.exit(code);
});

// 3. Esperar a que Julia esté listo
function waitForJulia() {
    return new Promise((resolve) => {
        console.log('⏳ Esperando a que Julia esté listo...');
        const checkJulia = () => {
            http.get(`http://localhost:${JULIA_PORT}/api/test`, (res) => {
                if (res.statusCode === 200) {
                    console.log('✅ Servidor Julia listo\n');
                    resolve();
                } else {
                    setTimeout(checkJulia, 500);
                }
            }).on('error', () => {
                setTimeout(checkJulia, 500);
            });
        };
        setTimeout(checkJulia, 2000);
    });
}

// 4. Servir frontend estático
function startFrontendServer() {
    const express = require('express');
    const app = express();
    
    // Servir archivos estáticos
    app.use(express.static(FRONTEND_DIR));
    
    // SPA fallback
    app.get('*', (req, res) => {
        res.sendFile(path.join(FRONTEND_DIR, 'index.html'));
    });
    
    app.listen(FRONTEND_PORT, 'localhost', () => {
        console.log('═══════════════════════════════════════════════');
        console.log('✅ MSL Process está listo');
        console.log('═══════════════════════════════════════════════');
        console.log(`🌐 Frontend: http://localhost:${FRONTEND_PORT}`);
        console.log(`🔷 Backend:  http://localhost:${JULIA_PORT}`);
        console.log('═══════════════════════════════════════════════');
        console.log('\n💡 Presiona Ctrl+C para cerrar\n');
        
        // Abrir navegador automáticamente
        const open = require('open');
        open(`http://localhost:${FRONTEND_PORT}`);
    });
}

// 5. Secuencia de inicio
(async () => {
    try {
        await waitForJulia();
        startFrontendServer();
    } catch (error) {
        console.error('❌ Error iniciando MSL Process:', error);
        process.exit(1);
    }
})();

// 6. Manejo de cierre limpio
process.on('SIGINT', () => {
    console.log('\n\n🛑 Cerrando MSL Process...');
    juliaProcess.kill();
    process.exit(0);
});

process.on('SIGTERM', () => {
    console.log('\n\n🛑 Cerrando MSL Process...');
    juliaProcess.kill();
    process.exit(0);
});