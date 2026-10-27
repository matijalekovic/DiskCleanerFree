'use strict';

const { contextBridge, ipcRenderer, webUtils } = require('electron');

contextBridge.exposeInMainWorld('api', {
  platformInfo: () => ipcRenderer.invoke('platform-info'),
  drives: () => ipcRenderer.invoke('drives'),
  specialFolders: () => ipcRenderer.invoke('special-folders'),
  chooseFolder: () => ipcRenderer.invoke('choose-folder'),

  startScan: (target, name, isDrive) => ipcRenderer.invoke('scan-start', { target, name, isDrive }),
  cancelScan: (session) => ipcRenderer.invoke('scan-cancel', session),
  forgetScan: (session) => ipcRenderer.invoke('scan-forget', session),
  onScanEvent: (callback) => ipcRenderer.on('scan-event', (_event, data) => callback(data)),
  tree: (session, method, args) => ipcRenderer.invoke('tree', { session, method, args }),

  confirmTrash: (count, size) => ipcRenderer.invoke('confirm-trash', { count, size }),
  trash: (session, items) => ipcRenderer.invoke('trash', { session, items }),
  cleanup: (session) => ipcRenderer.invoke('cleanup', { session }),
  exportCSV: (session, id, name) => ipcRenderer.invoke('export-csv', { session, id, name }),

  reveal: (target) => ipcRenderer.invoke('reveal', target),
  openPath: (target) => ipcRenderer.invoke('open-path', target),
  copyText: (text) => ipcRenderer.invoke('copy-text', text),
  fileIcon: (target) => ipcRenderer.invoke('file-icon', target),
  contextMenu: (items) => ipcRenderer.invoke('context-menu', items),
  openPrivacySettings: () => ipcRenderer.invoke('open-external-settings'),
  onThemeChanged: (callback) => ipcRenderer.on('theme-changed', () => callback()),
  launchFolders: () => ipcRenderer.invoke('launch-folders'),

  /** Path of a file dropped from Explorer/Finder. */
  pathForFile: (file) => webUtils.getPathForFile(file),
});
