// Connects the interface to the Rust backend (Tauri commands and events) as `window.api`.
'use strict';

(() => {
  const { invoke } = window.__TAURI__.core;
  const { listen } = window.__TAURI__.event;

  let pointer = { x: 0, y: 0 };
  const track = (event) => { pointer = { x: event.clientX, y: event.clientY }; };
  document.addEventListener('mousedown', track, true);
  document.addEventListener('contextmenu', track, true);

  /** Context menu drawn in the page; resolves with the chosen item's id, or null when dismissed. */
  function contextMenu(items) {
    return new Promise((resolve) => {
      document.querySelector('.menu')?.dispatchEvent(new Event('dismiss'));
      const menu = document.createElement('div');
      menu.className = 'menu';
      menu.setAttribute('role', 'menu');
      for (const item of items) {
        if (item.separator) {
          menu.appendChild(document.createElement('hr'));
          continue;
        }
        const button = document.createElement('button');
        button.textContent = item.label;
        button.disabled = item.enabled === false;
        button.addEventListener('click', () => finish(item.id));
        menu.appendChild(button);
      }
      document.body.appendChild(menu);
      const { innerWidth: w, innerHeight: h } = window;
      const box = menu.getBoundingClientRect();
      menu.style.left = `${Math.min(pointer.x, w - box.width - 8)}px`;
      menu.style.top = `${pointer.y + box.height > h - 8 ? Math.max(8, pointer.y - box.height) : pointer.y}px`;

      const outside = (event) => { if (!menu.contains(event.target)) finish(null); };
      const key = (event) => { if (event.key === 'Escape') { event.stopPropagation(); finish(null); } };
      function finish(choice) {
        menu.remove();
        document.removeEventListener('mousedown', outside, true);
        document.removeEventListener('keydown', key, true);
        window.removeEventListener('blur', dismiss);
        resolve(choice);
      }
      const dismiss = () => finish(null);
      menu.addEventListener('dismiss', dismiss);
      setTimeout(() => {
        document.addEventListener('mousedown', outside, true);
        document.addEventListener('keydown', key, true);
        window.addEventListener('blur', dismiss);
      }, 0);
    });
  }

  window.api = {
    platformInfo: () => invoke('platform_info'),
    drives: () => invoke('drives'),
    specialFolders: () => invoke('special_folders'),
    chooseFolder: () => invoke('choose_folder'),
    launchFolders: () => invoke('launch_folders'),

    startScan: (target, name, isDrive) => invoke('scan_start', { target, name, isDrive }),
    cancelScan: (session) => invoke('scan_cancel', { session }),
    forgetScan: (session) => invoke('scan_forget', { session }),
    onScanEvent: (callback) => listen('scan-event', (event) => callback(event.payload)),
    tree: (session, method, args) => invoke('tree', { session, method, args }),

    confirmTrash: (count, size) => invoke('confirm_trash', { count, size }),
    trash: (session, items) => invoke('trash', { session, items }),
    cleanup: (session) => invoke('cleanup', { session }),
    exportCSV: (session, id, name) => invoke('export_csv', { session, id, name }),

    reveal: (path) => invoke('reveal', { path }),
    openPath: (path) => invoke('open_path', { path }),
    copyText: (text) => invoke('copy_text', { text }),
    contextMenu,
    openPrivacySettings: () => invoke('open_privacy_settings'),
    onThemeChanged: (callback) => matchMedia('(prefers-color-scheme: dark)').addEventListener('change', callback),

    // Dropping files from Explorer isn't wired up; in-app drag and drop works.
    pathForFile: () => null,
  };
})();
