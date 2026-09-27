import { useCallback, useEffect, useState } from 'react';
import * as api from '../../services/api.js';
import { useProjectContext } from '../../context/ProjectContext.jsx';
import { useNativeDialogs } from '../../hooks/useNativeDialogs.js';
import { isCompatibleFile } from '../../utils/fileTree.js';

/** @typedef {import('../../types.js').SliceState} SliceState */

const EMPTY_SLICES = {
  sagittal: { num: 1, image: null },
  coronal: { num: 1, image: null },
  axial: { num: 1, image: null },
};

/**
 * Estado y lógica propios de Visualización. Reacciona a `selectedFile`
 * (verdad compartida en el contexto): cuando cambia el archivo
 * seleccionado, carga la imagen y los tres cortes centrales — igual que
 * `autoLoadFirstImage` en el App.js original, pero disparado por el efecto
 * en vez de acoplado al click del árbol de archivos.
 */
export function useVisualization() {
  const { selectedFile, project } = useProjectContext();
  const { notify } = useNativeDialogs();

  const [imageLoaded, setImageLoaded] = useState(false);
  const [imageDimensions, setImageDimensions] = useState(null);
  const [slices, setSlices] = useState(EMPTY_SLICES);

  const loadSlice = useCallback(async (orientation, sliceNum) => {
    if (!selectedFile) return;
    try {
      // `fullPath` (cuando existe) es la ruta absoluta real del archivo
      // dentro del proyecto — el backend la usa directo en vez de tener
      // que buscarla re-subida a TEMP_DIR. Ver FileResolver en el backend.
      const result = await api.getSlice({
        filename: selectedFile.fullPath || selectedFile.name,
        orientation,
        slice: sliceNum,
      });
      if (result.success) {
        setSlices((prev) => ({ ...prev, [orientation]: { num: sliceNum, image: result.image } }));
      }
    } catch (error) {
      console.error('Error cargando corte:', error);
    }
  }, [selectedFile]);

  useEffect(() => {
    if (!selectedFile || !isCompatibleFile(selectedFile.name, 'visualization')) {
      return undefined;
    }

    let cancelled = false;
    setImageLoaded(false);
    setSlices(EMPTY_SLICES);

    (async () => {
      try {
        const result = await api.loadImage(selectedFile.fullPath || selectedFile.name);
        if (cancelled) return;
        if (result.success) {
          setImageDimensions(result.dimensions);
          setImageLoaded(true);

          const [dimSagittal, dimCoronal, dimAxial] = result.dimensions;
          await Promise.all([
            loadSlice('sagittal', Math.floor(dimSagittal / 2)),
            loadSlice('coronal', Math.floor(dimCoronal / 2)),
            loadSlice('axial', Math.floor(dimAxial / 2)),
          ]);
        }
      } catch (error) {
        console.error('Error cargando imagen:', error);
      }
    })();

    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [selectedFile]);

  const saveImage = useCallback(async (orientation, sliceNum, imageData) => {
    if (!imageData || !selectedFile) {
      notify('No hay imagen para guardar');
      return;
    }
    try {
      const result = await api.guardarImagen({
        nombre_archivo: `${selectedFile.name.split('.')[0]}_${orientation}_corte${sliceNum}.png`,
        imagen_base64: imageData.split(',')[1],
        ruta_proyecto: project?.ruta || '',
      });
      if (result.success) {
        notify(`✅ Imagen guardada en:\n${result.ruta_completa}`);
      } else {
        notify(`❌ Error: ${result.error}`);
      }
    } catch (error) {
      console.error('Error:', error);
      notify('Error de conexión');
    }
  }, [selectedFile, project, notify]);

  return { selectedFile, imageLoaded, imageDimensions, slices, loadSlice, saveImage };
}
