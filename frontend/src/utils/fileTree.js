/** @typedef {import('../types.js').FileNode} FileNode */

/**
 * Determina si un archivo es compatible con el módulo activo.
 * Visualización y Radiómica: solo NIfTI/DICOM.
 * Estadística: NIfTI/DICOM o Excel (para comparar hojas de datos).
 *
 * @param {string} filename
 * @param {'visualization'|'radiomics'|'statistics'} [tab]
 */
export function isCompatibleFile(filename, tab = 'visualization') {
  const lowerName = filename.toLowerCase();
  const isNiftiOrDicom = /\.(nii|nii\.gz|dcm|dicom|ima)$/.test(lowerName);
  const isExcel = /\.(xlsx|xls)$/.test(lowerName);

  if (tab === 'statistics') {
    return isNiftiOrDicom || isExcel;
  }
  return isNiftiOrDicom;
}

/**
 * Construye un árbol jerárquico (mismo formato que devuelve el backend)
 * a partir de una FileList del selector `webkitdirectory` del navegador.
 *
 * @param {File[]} fileList
 * @param {string} rootName
 * @param {'visualization'|'radiomics'|'statistics'} activeTab
 * @returns {FileNode}
 */
export function buildTreeFromFiles(fileList, rootName, activeTab = 'visualization') {
  const root = { name: rootName, type: 'folder', path: rootName, children: [] };
  const folderMap = { [rootName]: root };

  for (const file of fileList) {
    const parts = file.webkitRelativePath.split('/');
    let currentPath = '';

    for (let i = 0; i < parts.length; i++) {
      const part = parts[i];
      const isFile = i === parts.length - 1;
      currentPath = currentPath ? `${currentPath}/${part}` : part;

      if (!folderMap[currentPath]) {
        const newNode = {
          name: part,
          type: isFile ? 'file' : 'folder',
          path: currentPath,
          ...(isFile && { file, compatible: isCompatibleFile(file.name, activeTab) }),
          ...(!isFile && { children: [] }),
        };

        const parentPath = currentPath.substring(0, currentPath.lastIndexOf('/'));
        const parent = folderMap[parentPath] || root;
        parent.children.push(newNode);
        folderMap[currentPath] = newNode;
      }
    }
  }

  return root;
}

/** @param {FileNode} node */
export function findFirstCompatibleFile(node) {
  if (node.type === 'file' && isCompatibleFile(node.name, 'visualization')) {
    return node;
  }
  if (node.children) {
    for (const child of node.children) {
      const found = findFirstCompatibleFile(child);
      if (found) return found;
    }
  }
  return null;
}

/**
 * @param {FileNode} node
 * @param {'visualization'|'radiomics'|'statistics'} activeTab
 * @returns {FileNode[]}
 */
export function extractAllCompatibleFiles(node, activeTab = 'visualization') {
  if (!node) return [];
  let files = [];
  if (node.type === 'file' && isCompatibleFile(node.name, activeTab)) {
    files.push(node);
  }
  if (node.children) {
    for (const child of node.children) {
      files = files.concat(extractAllCompatibleFiles(child, activeTab));
    }
  }
  return files;
}

/** Aplana el árbol y devuelve solo las carpetas de primer nivel. */
export function firstLevelFolders(node) {
  if (!node || !node.children) return [];
  return node.children.filter((child) => child.type === 'folder');
}

/**
 * Normaliza la ruta de una carpeta del árbol a lo que espera el backend en
 * `carpeta_destino`: relativa a `ruta_proyecto`, sin el nombre de la carpeta
 * raíz adelante.
 *
 * Los árboles que arma el backend (`escanear_directorio_recursivo`) ya
 * vienen así. Los que arma `buildTreeFromFiles` (selector de navegador,
 * fallback) incluyen el nombre de la raíz al principio de cada `path` — acá
 * se le saca antes de mandarlo al backend.
 *
 * @param {string} path
 * @param {string} rootName - `structure.name` del árbol activo.
 */
export function relativeToProjectRoot(path, rootName) {
  if (rootName && path.startsWith(`${rootName}/`)) {
    return path.slice(rootName.length + 1);
  }
  return path;
}
