// Main process: window, drives, scan sessions (one worker each), deleting to the Recycle Bin.
'use strict';

const { app, BrowserWindow, ipcMain, dialog, shell, Menu, nativeTheme, systemPreferences, clipboard } = require('electron');
const { Worker } = require('worker_threads');
const { execFile } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const cleanup = require('./cleanup');

const isWindows = process.platform === 'win32';
const isMac = process.platform === 'darwin';
let window = null;

// ---- Window

function themeColors() {
  const dark = nativeTheme.shouldUseDarkColors;
  return { color: '#00000000', symbolColor: dark ? '#ffffff' : '#1b1b1f', height: 52 };
}

function createWindow() {
  window = new BrowserWindow({
    width: 1280,
    height: 820,
    minWidth: 760,
    minHeight: 540,
    show: false,
    title: 'Disk Cleaner Free',
    backgroundColor: isWindows ? '#00000000' : (nativeTheme.shouldUseDarkColors ? '#1c1c20' : '#f3f3f6'),
    titleBarStyle: isMac ? 'hiddenInset' : 'hidden',
    ...(isWindows ? { titleBarOverlay: themeColors(), backgroundMaterial: 'mica' } : {}),
    ...(isMac ? { vibrancy: 'sidebar', visualEffectState: 'active', trafficLightPosition: { x: 18, y: 18 } } : {}),
    icon: path.join(__dirname, '..', 'build', 'icon.png'),
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });
  window.removeMenu?.();
  window.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  window.once('ready-to-show', () => window.show());

  if (!app.isPackaged) {
    // Development: surface renderer errors in the terminal.
    window.webContents.on('console-message', (event) => {
      const { level, message, lineNumber, sourceId } = event;
      if (level === 'warning' || level === 'error' || level >= 2) console.log(`[renderer ${level}] ${message} (${sourceId}:${lineNumber})`);
    });
  }
  nativeTheme.on('updated', () => {
    if (isWindows) window.setTitleBarOverlay(themeColors());
    window.webContents.send('theme-changed');
  });
}

app.whenReady().then(() => {
  if (isMac) {
    Menu.setApplicationMenu(Menu.buildFromTemplate([
      { role: 'appMenu' }, { role: 'editMenu' }, { role: 'windowMenu' },
    ]));
  } else {
    Menu.setApplicationMenu(null);
  }
  createWindow();
  app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
});

app.on('window-all-closed', () => {
  for (const session of sessions.values()) session.worker.terminate();
  app.quit();
});

// ---- Drives

function capacity(target) {
  try {
    const st = fs.statfsSync(target);
    const total = st.blocks * st.bsize;
    const free = st.bavail * st.bsize;
    return total > 0 ? { total, free, used: total - free } : null;
  } catch {
    return null;
  }
}

function windowsVolumeLabels() {
  return new Promise((resolve) => {
    execFile('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command',
      'Get-Volume | Where-Object DriveLetter | Select-Object DriveLetter,FileSystemLabel,DriveType | ConvertTo-Json -Compress'],
    { timeout: 5000, windowsHide: true }, (error, stdout) => {
      if (error) return resolve({});
      try {
        const parsed = JSON.parse(stdout);
        const list = Array.isArray(parsed) ? parsed : [parsed];
        resolve(Object.fromEntries(list.map((v) => [String(v.DriveLetter).toUpperCase(), v])));
      } catch {
        resolve({});
      }
    });
  });
}

async function listDrives() {
  if (isWindows) {
    const labels = await windowsVolumeLabels();
    const drives = [];
    for (let code = 67; code <= 90; code++) { // C..Z
      const letter = String.fromCharCode(code);
      const root = letter + ':\\';
      if (!fs.existsSync(root)) continue;
      const cap = capacity(root);
      if (!cap) continue;
      const info = labels[letter] || {};
      const fallback = info.DriveType === 'Removable' ? 'USB Drive' : 'Local Disk';
      drives.push({ path: root, name: `${info.FileSystemLabel || fallback} (${letter}:)`, isSystem: letter === 'C',
        removable: info.DriveType === 'Removable', ...cap });
    }
    return drives;
  }
  const drives = [];
  const rootCap = capacity('/');
  if (rootCap) drives.push({ path: '/', name: isMac ? 'Macintosh HD' : 'System', isSystem: true, ...rootCap });
  const mounts = isMac ? '/Volumes' : '/media';
  try {
    for (const entry of fs.readdirSync(mounts, { withFileTypes: true })) {
      const full = path.join(mounts, entry.name);
      if (entry.isSymbolicLink()) continue; // e.g. /Volumes/Macintosh HD → /
      const cap = capacity(full);
      if (cap) drives.push({ path: full, name: entry.name, isSystem: false, removable: true, ...cap });
    }
  } catch { /* no mounts folder */ }
  return drives;
}

ipcMain.handle('drives', () => listDrives());

/** Folders passed on the command line (e.g. dropped onto the app's icon); the window asks once it's ready. */
ipcMain.handle('launch-folders', () => process.argv.slice(app.isPackaged ? 1 : 2)
  .filter((arg) => !arg.startsWith('-'))
  .filter((arg) => { try { return fs.statSync(arg).isDirectory(); } catch { return false; } })
  .map((arg) => path.resolve(arg)));

ipcMain.handle('special-folders', () => [
  { path: os.homedir(), name: path.basename(os.homedir()), icon: 'home' },
  { path: app.getPath('downloads'), name: 'Downloads', icon: 'download' },
  { path: app.getPath('documents'), name: 'Documents', icon: 'document' },
]);

ipcMain.handle('choose-folder', async () => {
  const result = await dialog.showOpenDialog(window, { properties: ['openDirectory'], buttonLabel: 'Scan' });
  return result.canceled ? null : result.filePaths[0];
});

// ---- Scan sessions

const sessions = new Map();
let nextSession = 1;

function request(session, method, args) {
  return new Promise((resolve, reject) => {
    const requestId = session.nextRequest++;
    session.pending.set(requestId, { resolve, reject });
    session.worker.postMessage({ requestId, method, args });
  });
}

ipcMain.handle('scan-start', (_event, { target, name, isDrive }) => {
  const id = nextSession++;
  const cancelBuffer = new SharedArrayBuffer(4);
  const cap = isDrive ? capacity(target) : null;
  const worker = new Worker(path.join(__dirname, 'scan-worker.js'), {
    workerData: { path: target, name, cancelBuffer, usedBytes: cap ? cap.used : 0 },
  });
  const session = { id, worker, cancel: new Int32Array(cancelBuffer), pending: new Map(), nextRequest: 1, target };
  sessions.set(id, session);
  worker.on('message', (message) => {
    if (message.requestId) {
      const pending = session.pending.get(message.requestId);
      session.pending.delete(message.requestId);
      if (!pending) return;
      if (message.error) pending.reject(new Error(message.error)); else pending.resolve(message.value);
      return;
    }
    window?.webContents.send('scan-event', { session: id, ...message, capacity: cap });
  });
  worker.on('error', (error) => window?.webContents.send('scan-event', { session: id, type: 'error', message: String(error.message || error) }));
  return id;
});

ipcMain.handle('scan-cancel', (_event, id) => {
  const session = sessions.get(id);
  if (session) Atomics.store(session.cancel, 0, 1);
});

ipcMain.handle('scan-forget', (_event, id) => {
  const session = sessions.get(id);
  if (!session) return;
  Atomics.store(session.cancel, 0, 1);
  session.worker.terminate();
  sessions.delete(id);
});

ipcMain.handle('tree', (_event, { session, method, args }) => {
  const s = sessions.get(session);
  if (!s) throw new Error('Scan is no longer available');
  return request(s, method, args);
});

/** Moves items to the Recycle Bin (Trash on macOS), then prunes them from the tree. */
ipcMain.handle('trash', async (_event, { session, items }) => {
  const s = sessions.get(session);
  const done = [];
  const failed = [];
  for (const item of items) {
    try {
      await shell.trashItem(item.path);
      done.push(item.id);
    } catch {
      failed.push(item.name);
    }
  }
  const totals = s && done.length ? await request(s, 'remove', { ids: done }) : null;
  return { done, failed, totals };
});

ipcMain.handle('confirm-trash', async (_event, { count, size }) => {
  const bin = isWindows ? 'Recycle Bin' : 'Trash';
  const result = await dialog.showMessageBox(window, {
    type: 'warning',
    buttons: [`Move to ${bin}`, 'Cancel'],
    defaultId: 0,
    cancelId: 1,
    message: `Move ${count} item${count === 1 ? '' : 's'} (${size}) to the ${bin}?`,
    detail: `Empty the ${bin} afterwards to actually free the space.`,
  });
  return result.response === 0;
});

ipcMain.handle('cleanup', async (_event, { session }) => {
  const s = sessions.get(session);
  if (!s) return [];
  const result = [];
  for (const category of cleanup.categories()) {
    let ids = [];
    if (category.contentsOf) {
      const parents = await request(s, 'find', { paths: category.contentsOf });
      for (const parentId of parents.filter((id) => id >= 0)) {
        const kids = await request(s, 'children', { id: parentId });
        ids.push(...kids.filter((k) => k.size > 0 && (!category.exclude || !category.exclude(k.name))).map((k) => k.id));
      }
    } else {
      ids = (await request(s, 'find', { paths: category.paths })).filter((id) => id >= 0);
    }
    const items = (await request(s, 'info', { ids })).filter((item) => item.size > 0);
    if (items.length) {
      const { contentsOf, exclude, paths, ...rest } = category;
      result.push({ ...rest, items });
    }
  }
  return result;
});

ipcMain.handle('export-csv', async (_event, { session, id, name }) => {
  const s = sessions.get(session);
  if (!s) return false;
  const result = await dialog.showSaveDialog(window, { defaultPath: `${name} scan.csv`, filters: [{ name: 'CSV', extensions: ['csv'] }] });
  if (result.canceled || !result.filePath) return false;
  fs.writeFileSync(result.filePath, await request(s, 'csv', { id }));
  return true;
});

// ---- Shell helpers

ipcMain.handle('reveal', (_event, target) => shell.showItemInFolder(target));
ipcMain.handle('open-path', (_event, target) => shell.openPath(target));
ipcMain.handle('copy-text', (_event, text) => clipboard.writeText(text));
ipcMain.handle('open-external-settings', () => {
  if (isMac) shell.openExternal('x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles');
});

const iconCache = new Map();
ipcMain.handle('file-icon', async (_event, target) => {
  if (iconCache.has(target)) return iconCache.get(target);
  try {
    const url = (await app.getFileIcon(target, { size: 'normal' })).toDataURL();
    iconCache.set(target, url);
    return url;
  } catch {
    return null;
  }
});

/** Native context menu; resolves with the id of the chosen item (or null). */
ipcMain.handle('context-menu', (_event, items) => new Promise((resolve) => {
  let chosen = null;
  const template = items.map((item) => item.separator ? { type: 'separator' } : {
    label: item.label, enabled: item.enabled !== false, click: () => { chosen = item.id; },
  });
  Menu.buildFromTemplate(template).popup({ window, callback: () => resolve(chosen) });
}));

ipcMain.handle('platform-info', () => ({
  platform: process.platform,
  accent: isWindows || isMac ? '#' + systemPreferences.getAccentColor().slice(0, 6) : '#0a84ff',
  bin: isWindows ? 'Recycle Bin' : 'Trash',
  fileManager: isWindows ? 'File Explorer' : isMac ? 'Finder' : 'Files',
}));
