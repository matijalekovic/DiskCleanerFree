// Line icons (24×24, stroke = currentColor), in the spirit of Fluent / SF Symbols.
'use strict';

const ICONS = {
  sidebar: '<rect x="3" y="4" width="18" height="16" rx="3"/><path d="M9 4v16"/>',
  list: '<rect x="3" y="4" width="18" height="16" rx="3"/><path d="M15 4v16"/>',
  folderAdd: '<path d="M3 7.5A2.5 2.5 0 0 1 5.5 5H9l2 2h7.5A2.5 2.5 0 0 1 21 9.5v8a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 17.5z"/><path d="M12 11v5M9.5 13.5h5"/>',
  folder: '<path d="M3 7.5A2.5 2.5 0 0 1 5.5 5H9l2 2h7.5A2.5 2.5 0 0 1 21 9.5v8a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 17.5z"/>',
  drive: '<rect x="3" y="12" width="18" height="7" rx="2"/><path d="M5 12l2.2-6.2A2 2 0 0 1 9.1 4.5h5.8a2 2 0 0 1 1.9 1.3L19 12"/><circle cx="16.5" cy="15.5" r=".9" fill="currentColor"/>',
  home: '<path d="M4 10.5 12 4l8 6.5V19a1 1 0 0 1-1 1h-4.5v-5.5h-5V20H5a1 1 0 0 1-1-1z"/>',
  download: '<path d="M12 4v11M7.5 10.5 12 15l4.5-4.5M5 19.5h14"/>',
  document: '<path d="M7 3.5h6.5L18 8v12.5H7z"/><path d="M13.5 3.5V8H18"/>',
  back: '<path d="M14.5 5.5 8 12l6.5 6.5"/>',
  forward: '<path d="M9.5 5.5 16 12l-6.5 6.5"/>',
  refresh: '<path d="M19 12a7 7 0 1 1-2.05-4.95"/><path d="M19 4.5v4h-4"/>',
  chevronUp: '<path d="M6.5 14.5 12 9l5.5 5.5"/>',
  chevronDown: '<path d="M6.5 9.5 12 15l5.5-5.5"/>',
  chevronRight: '<path d="M9.5 6.5 15 12l-5.5 5.5"/>',
  tray: '<path d="M4 13.5 6.5 5h11L20 13.5V19H4z"/><path d="M4 13.5h4.5a3.5 3.5 0 0 0 7 0H20"/>',
  trayFull: '<path d="M4 13.5 6.5 5h11L20 13.5V19H4z"/><path d="M4 13.5h4.5a3.5 3.5 0 0 0 7 0H20"/><path d="M9 8.5h6M8.2 11h7.6"/>',
  trash: '<path d="M5 7h14M10 4h4M7 7l.8 12.2a1 1 0 0 0 1 .8h6.4a1 1 0 0 0 1-.8L17 7"/><path d="M10.5 10.5v6M13.5 10.5v6"/>',
  x: '<path d="M6.5 6.5l11 11M17.5 6.5l-11 11"/>',
  xCircle: '<circle cx="12" cy="12" r="8.5"/><path d="M9.3 9.3l5.4 5.4M14.7 9.3l-5.4 5.4"/>',
  reveal: '<circle cx="11" cy="11" r="6"/><path d="M15.5 15.5 20 20"/>',
  sparkles: '<path d="M10 3.5l1.6 4.4L16 9.5l-4.4 1.6L10 15.5l-1.6-4.4L4 9.5l4.4-1.6z"/><path d="M17.5 13.5l.8 2.2 2.2.8-2.2.8-.8 2.2-.8-2.2-2.2-.8 2.2-.8z"/>',
  lock: '<rect x="5" y="10.5" width="14" height="9.5" rx="2"/><path d="M8 10.5V8a4 4 0 0 1 8 0v2.5"/>',
  shield: '<path d="M12 3.5 19 6v5.5c0 4.3-3 7.6-7 9-4-1.4-7-4.7-7-9V6z"/>',
  check: '<path d="M5.5 12.5l4 4 9-9"/>',
  pie: '<path d="M12 3.5a8.5 8.5 0 1 0 8.5 8.5H12z"/><path d="M15 3.9A8.5 8.5 0 0 1 20.1 9H15z"/>',
  more: '<circle cx="6" cy="12" r="1.2" fill="currentColor"/><circle cx="12" cy="12" r="1.2" fill="currentColor"/><circle cx="18" cy="12" r="1.2" fill="currentColor"/>',
  export: '<path d="M12 15V4M7.5 8.5 12 4l4.5 4.5M5 14v5.5h14V14"/>',
};

function icon(name, size = 18) {
  return `<svg class="icon" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${ICONS[name] || ''}</svg>`;
}

/** Fills every element with a data-icon attribute. */
function hydrateIcons(root = document) {
  for (const el of root.querySelectorAll('[data-icon]')) {
    if (!el.dataset.iconDone) {
      el.insertAdjacentHTML('afterbegin', icon(el.dataset.icon, Number(el.dataset.iconSize) || 18));
      el.dataset.iconDone = '1';
    }
  }
}
