import { useCallback, useEffect, useState } from 'react';
import { testConnection, getInfo } from '../services/api.js';

/**
 * Verifica y mantiene el estado de conexión con el backend.
 * Reutilizable por cualquier parte de la app que necesite saber si el
 * servidor Julia está disponible (hoy solo lo usa el shell/Header).
 */
export function useBackendStatus() {
  const [status, setStatus] = useState('checking'); // 'checking' | 'connected' | 'disconnected'
  const [info, setInfo] = useState(null);

  const check = useCallback(async () => {
    try {
      const data = await testConnection();
      if (data.status === 'ok') {
        setStatus('connected');
        const infoData = await getInfo();
        setInfo(infoData);
      } else {
        setStatus('disconnected');
      }
    } catch (error) {
      console.error('Error conectando con Julia:', error);
      setStatus('disconnected');
    }
  }, []);

  useEffect(() => {
    check();
  }, [check]);

  return { status, info, recheck: check };
}
