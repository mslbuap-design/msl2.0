#!/usr/bin/env node

const { spawn } = require('child_process');
const http = require('http');
const path = require('path');
const fs = require('fs');
const os = require('os');

console.log('═══════════════════════════════════════════════');
console.log('    🌐 MSL Process - Modo Servidor (Red Local)');
console.log('═══════════════════════════════════════════════\n');

const JULIA_PORT = 8000;
const FRONTEND_PORT = 3000;
const BACKEND_DIR = path.join(__dirname, '..', 'backend');
const FRONTEND_DIR = path.join(__dirname, '..', 'frontend', 'build-server');

// Detectar número de cores
const numCores = os.cpus().length;
console.log(`🧵 CPU Cores detectados: ${numCores}`);

// Detectar IP local
function getLocalIP() {
    const interfaces = os.networkInterfaces();
    for (const name of Object.keys(interfaces)) {
        for (const iface of interfaces[name]) {
            if (iface.family === 'IPv4' && !iface.internal) {
                return iface.address;
            }
        }
    }
    return 'localhost';
}

const localIP = getLocalIP();
console.log(`🌐 IP del servidor: ${localIP}`);
console.log(`📡 URL para clientes: http://${localIP}:${FRONTEND_PORT}\n`);

// 1. Verificar directorios
if (!fs.existsSync(BACKEND_DIR)) {
    console.error('❌ Error: No se encontró el directorio backend');
    process.exit(1);
}

if (!fs.existsSync(FRONTEND_DIR)) {
    console.error('❌ Error: No se encontró el frontend compilado para servidor');
    console.error(`   Buscado en: ${FRONTEND_DIR}`);
    console.error('\n💡 Solución:');
    console.error('   cd frontend');
    console.error('   cp .env.server .env');
    console.error('   npm run build');
    console.error('   mv build ../build-server');
    process.exit(1);
}

// 2. Iniciar Julia en modo servidor
console.log('🔷 Iniciando servidor Julia (modo red)...');

const startScript = path.join(BACKEND_DIR, 'scripts', 'start-server.sh');

const juliaProcess = spawn('bash', [startScript], {
    cwd: BACKEND_DIR,
    stdio: ['ignore', 'pipe', 'pipe'],
    env: { ...process.env, MSL_SERVER_MODE: 'server' }
});

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

// 3. Esperar a Julia
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

// 4. Servir frontend en toda la red
function startFrontendServer() {
    const express = require('express');
    const app = express();
    
    // Middleware de logging
    app.use((req, res, next) => {
        console.log(`📡 ${req.method} ${req.url} desde ${req.ip}`);
        next();
    });
    
    // Servir archivos estáticos
    app.use(express.static(FRONTEND_DIR));
    
    // SPA fallback
    app.get('*', (req, res) => {
        res.sendFile(path.join(FRONTEND_DIR, 'index.html'));
    });
    
    // Escuchar en toda la red (0.0.0.0)
    app.listen(FRONTEND_PORT, '0.0.0.0', () => {
        console.log('═══════════════════════════════════════════════');
        console.log('✅ MSL Process Servidor está listo');
        console.log('═══════════════════════════════════════════════');
        console.log(`🌐 Acceso local:  http://localhost:${FRONTEND_PORT}`);
        console.log(`📡 Acceso red:    http://${localIP}:${FRONTEND_PORT}`);
        console.log(`🔷 Backend Julia: http://${localIP}:${JULIA_PORT}`);
        console.log('═══════════════════════════════════════════════');
        console.log('\n📱 Dispositivos en la red pueden acceder desde:');
        console.log(`   http://${localIP}:${FRONTEND_PORT}\n`);
        console.log('💡 Presiona Ctrl+C para cerrar\n');
    });
}

// 5. Secuencia de inicio
(async () => {
    try {
        await waitForJulia();
        startFrontendServer();
    } catch (error) {
        console.error('❌ Error iniciando servidor:', error);
        process.exit(1);
    }
})();

// 6. Manejo de cierre
process.on('SIGINT', () => {
    console.log('\n\n🛑 Cerrando servidor MSL Process...');
    juliaProcess.kill();
    process.exit(0);
});

process.on('SIGTERM', () => {
    console.log('\n\n🛑 Cerrando servidor MSL Process...');
    juliaProcess.kill();
    process.exit(0);
});