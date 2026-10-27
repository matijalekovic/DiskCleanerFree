// Window logic: sources sidebar, overview, scanning, and the report (map, list, Collector).
'use strict';

// `api` is the bridge exposed by preload.js (window.api).
const KIND = Sunburst.KIND;
const DEPTH = 6;
const $ = (selector, root = document) => root.querySelector(selector);
const esc = (value) => String(value).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const state = {
  info: { platform: 'win32', bin: 'Recycle Bin', fileManager: 'File Explorer' },
  drives: [],
  specials: [],
  recents: [],
  selectedKey: null,
  sessions: new Map(),
  listVisible: true,
  sidebarHidden: false,
  sidebarAutoHidden: false,
  reportKey: null,
};

const isMacLike = () => state.info.platform === 'darwin';
const primaryModifier = (event) => (isMacLike() ? event.metaKey : event.ctrlKey);

// ---------------------------------------------------------------- Sources

function sourceFor(key) {
  const drive = state.drives.find((d) => d.path === key);
  if (drive) return { key, path: drive.path, name: drive.name, isDrive: true, drive };
  const special = state.specials.find((s) => s.path === key);
  if (special) return { key, path: special.path, name: special.name, isDrive: false, icon: special.icon };
  const recent = state.recents.find((r) => r.path === key);
  if (recent) return { key, path: recent.path, name: recent.name, isDrive: false, icon: 'folder' };
  return null;
}

async function refreshDrives() {
  state.drives = await api.drives();
  renderSidebar();
}

function select(key) {
  state.selectedKey = key;
  render();
}

function openFolder(folderPath) {
  const drive = state.drives.find((d) => d.path === folderPath);
  if (drive) { select(drive.path); startScan(drive.path); return; }
  if (!state.specials.some((s) => s.path === folderPath) && !state.recents.some((r) => r.path === folderPath)) {
    const name = folderPath.split(/[\\/]/).filter(Boolean).pop() || folderPath;
    state.recents.unshift({ path: folderPath, name });
  }
  select(folderPath);
  startScan(folderPath);
}

// ---------------------------------------------------------------- Scanning

async function startScan(key) {
  const source = sourceFor(key);
  if (!source) return;
  const old = state.sessions.get(key);
  if (old?.id) api.forgetScan(old.id);
  const session = {
    key, source, id: null, status: 'scanning', progress: { files: 0, bytes: 0, current: source.path },
    startedAt: Date.now(), focus: 0, back: [], forward: [], view: null, model: null, hovered: null,
    selection: new Map(), anchor: null, collected: new Map(), within: new Map(), expandedList: false,
    allChildren: null, drawerOpen: false, deleting: false, restricted: 0, capacity: null, toast: null,
  };
  state.sessions.set(key, session);
  if (state.reportKey === key) state.reportKey = null;
  render();
  session.id = await api.startScan(source.path, source.name, source.isDrive);
}

api.onScanEvent(async (event) => {
  const session = [...state.sessions.values()].find((s) => s.id === event.session);
  if (!session) return;
  if (event.type === 'progress') {
    session.progress = event;
    if (state.selectedKey === session.key) updateScanning(session);
    return;
  }
  if (event.type === 'done') {
    session.status = 'done';
    session.restricted = event.restricted;
    session.capacity = event.capacity;
    await loadView(session);
  } else if (event.type === 'cancelled') {
    state.sessions.delete(session.key);
  } else if (event.type === 'error') {
    session.status = 'failed';
    session.error = event.message;
  }
  render();
});

async function loadView(session) {
  session.view = await api.tree(session.id, 'view', {
    id: session.focus, depth: DEPTH, minFraction: Sunburst.minFraction, listLimit: 120,
  });
  session.focus = session.view.node.id;
  session.model = Sunburst.layout(session.view.rings, session.view.node.size, DEPTH);
  session.allChildren = session.expandedList ? await api.tree(session.id, 'children', { id: session.focus }) : null;
}

async function navigate(session, id, { record = true } = {}) {
  if (id === session.focus) return;
  if (record) { session.back.push(session.focus); session.forward = []; }
  session.focus = id;
  session.hovered = null;
  session.selection.clear();
  session.expandedList = false;
  await loadView(session);
  updateReport(session, { animate: true });
}

const goBack = (s) => { if (s.back.length) { s.forward.push(s.focus); navigate(s, s.back.pop(), { record: false }); } };
const goForward = (s) => { if (s.forward.length) { s.back.push(s.focus); navigate(s, s.forward.pop(), { record: false }); } };
const goUp = (s) => { const lineage = s.view?.lineage; if (lineage && lineage.length > 1) navigate(s, lineage[lineage.length - 2].id); };

// ---------------------------------------------------------------- Collector

function recomputeWithin(session) {
  session.within = new Map();
  for (const item of session.collected.values()) {
    for (const id of [item.id, ...item.ancestors]) session.within.set(id, (session.within.get(id) || 0) + item.size);
  }
}

const collectedSize = (s) => [...s.collected.values()].reduce((sum, item) => sum + item.size, 0);

function insideCollected(session, id) {
  if (session.collected.has(id)) return true;
  // Ancestors of rows on screen are known from the view lineage and the segment tree.
  const parents = session.model?.parents;
  let current = parents?.get(id);
  while (current !== undefined && current !== null) {
    if (session.collected.has(current)) return true;
    current = parents.get(current);
  }
  return session.view?.lineage.some((n) => session.collected.has(n.id)) || false;
}

/** Size once collected items are gone; a collected item shows what it frees. */
function remaining(session, id, size) {
  if (session.collected.has(id)) return size;
  return size - (session.within.get(id) || 0);
}

async function collect(session, ids) {
  let wanted = ids.filter((id) => id > 0);
  if (wanted.some((id) => session.selection.has(id))) wanted = [...new Set([...wanted, ...session.selection.keys()])];
  if (!wanted.length) return;
  const items = await api.tree(session.id, 'info', { ids: wanted });
  for (const item of items) {
    if (item.kind === KIND.HIDDEN) continue;
    if (session.collected.has(item.id) || item.ancestors.some((a) => session.collected.has(a))) continue;
    for (const existing of [...session.collected.values()]) {
      if (existing.ancestors.includes(item.id)) session.collected.delete(existing.id);
    }
    session.collected.set(item.id, item);
  }
  recomputeWithin(session);
  updateReport(session);
}

function uncollect(session, id) {
  session.collected.delete(id);
  recomputeWithin(session);
  updateReport(session);
}

function clearCollector(session) {
  session.collected.clear();
  recomputeWithin(session);
  updateReport(session);
}

async function trashCollected(session) {
  const items = [...session.collected.values()];
  if (!items.length || session.deleting) return;
  const ok = await api.confirmTrash(items.length, Format.bytes(collectedSize(session)));
  if (!ok) return;
  session.deleting = true;
  updateReport(session);
  const result = await api.trash(session.id, items.map((i) => ({ id: i.id, path: i.path, name: i.name })));
  const freed = items.filter((i) => result.done.includes(i.id)).reduce((sum, i) => sum + i.size, 0);
  for (const id of result.done) session.collected.delete(id);
  recomputeWithin(session);
  session.back = session.back.filter((id) => !result.done.includes(id));
  session.forward = session.forward.filter((id) => !result.done.includes(id));
  session.deleting = false;
  session.toast = freed > 0 ? { freed, failed: result.failed.length } : result.failed.length ? { freed: 0, failed: result.failed.length } : null;
  await loadView(session);
  updateReport(session);
  refreshDrives();
  setTimeout(() => { session.toast = null; if (state.selectedKey === session.key) renderToast(session); }, 4500);
}

// ---------------------------------------------------------------- Selection

function rowOrder(session) {
  return (session.allChildren || session.view?.list || []).map((n) => n.id);
}

function clickRow(session, id, event) {
  const node = findListNode(session, id);
  if (!node) return;
  if (node.kind === KIND.HIDDEN) return;
  if (primaryModifier(event)) {
    if (session.selection.has(id)) session.selection.delete(id); else session.selection.set(id, true);
    session.anchor = id;
  } else if (event.shiftKey && session.anchor !== null) {
    const order = rowOrder(session);
    const a = order.indexOf(session.anchor);
    const b = order.indexOf(id);
    if (a >= 0 && b >= 0) {
      session.selection = new Map(order.slice(Math.min(a, b), Math.max(a, b) + 1).map((x) => [x, true]));
    }
  } else if (event.detail >= 2) {
    openNode(session, node);
    return;
  } else {
    session.selection = new Map([[id, true]]);
    session.anchor = id;
  }
  refreshSelection(session);
}

function openNode(session, node) {
  if (node.hasChildren) navigate(session, node.id);
  else api.tree(session.id, 'info', { ids: [node.id] }).then(([info]) => info && api.openPath(info.path));
}

function findListNode(session, id) {
  return (session.allChildren || session.view?.list || []).find((n) => n.id === id);
}

function refreshSelection(session) {
  for (const row of document.querySelectorAll('.row[data-id]')) {
    row.classList.toggle('selected', session.selection.has(Number(row.dataset.id)));
  }
  drawMap(session);
}

// ---------------------------------------------------------------- Context menus

async function nodeMenu(session, id) {
  const [info] = await api.tree(session.id, 'info', { ids: [id] });
  if (!info) return;
  if (info.kind === KIND.HIDDEN) return;
  const multi = session.selection.has(id) && session.selection.size > 1;
  const collectedHere = session.collected.has(id);
  const items = [
    ...(info.hasChildren ? [{ id: 'zoom', label: 'Zoom In' }] : []),
    { id: 'open', label: 'Open' },
    { id: 'reveal', label: `Show in ${state.info.fileManager}` },
    { id: 'copy', label: 'Copy Path' },
    { separator: true },
    multi ? { id: 'collect-all', label: `Move ${session.selection.size} Items to Collector` }
      : collectedHere ? { id: 'uncollect', label: 'Remove from Collector' }
        : { id: 'collect', label: 'Move to Collector', enabled: !insideCollected(session, id) },
  ];
  const choice = await api.contextMenu(items);
  if (choice === 'zoom') navigate(session, id);
  else if (choice === 'open') api.openPath(info.path);
  else if (choice === 'reveal') api.reveal(info.path);
  else if (choice === 'copy') api.copyText(info.path);
  else if (choice === 'collect') collect(session, [id]);
  else if (choice === 'collect-all') collect(session, [...session.selection.keys()]);
  else if (choice === 'uncollect') uncollect(session, id);
}

// ---------------------------------------------------------------- Rendering: shell

function render() {
  renderSidebar();
  const session = state.sessions.get(state.selectedKey);
  const source = sourceFor(state.selectedKey);
  const view = $('#view');
  $('#toolbar').innerHTML = '';
  if (!source) {
    state.reportKey = null;
    setTitle('Disk Cleaner Free', '');
    view.innerHTML = `<div class="overview"><div class="empty-state"><strong>Choose a disk</strong>
      Pick a drive in the sidebar, or drop a folder here to see what takes up its space.</div></div>`;
    return;
  }
  if (session?.status === 'scanning') {
    state.reportKey = null;
    renderScanning(session);
  } else if (session?.status === 'done') {
    renderReport(session);
  } else {
    state.reportKey = null;
    renderOverview(source, session);
  }
}

function setTitle(title, subtitle) {
  $('#title').textContent = title;
  $('#subtitle').textContent = subtitle;
}

function renderSidebar() {
  const sessionBadge = (key) => {
    const s = state.sessions.get(key);
    if (s?.status === 'scanning') return '<span class="spinner"></span>';
    if (s?.status === 'done') return '<span class="badge-dot"></span>';
    return '';
  };
  const driveRows = state.drives.map((d) => {
    const used = d.total ? d.used / d.total : 0;
    return `<div class="source ${state.selectedKey === d.path ? 'active' : ''}" data-key="${esc(d.path)}">
      ${icon('drive', 26)}
      <div class="source-main">
        <div class="source-name">${esc(d.name)}</div>
        <div class="capacity-bar"><span class="${used > 0.9 ? 'full' : ''}" style="width:${(used * 100).toFixed(1)}%"></span></div>
        <div class="source-sub tabular">${Format.bytes(d.free)} free of ${Format.bytes(d.total)}</div>
      </div>${sessionBadge(d.path)}</div>`;
  }).join('');
  const folderRow = (f) => {
    const s = state.sessions.get(f.path);
    const size = s?.status === 'done' && s.view ? `<span class="source-size tabular">${Format.bytes(s.view.rootSize)}</span>` : '';
    return `<div class="source ${state.selectedKey === f.path ? 'active' : ''}" data-key="${esc(f.path)}" title="${esc(f.path)}">
      ${icon(f.icon || 'folder', 20)}<div class="source-main"><div class="source-name">${esc(f.name)}</div></div>${size}${sessionBadge(f.path)}</div>`;
  };
  $('#sources').innerHTML = `
    <div class="source-section"><h3>${isMacLike() ? 'Disks' : 'Drives'}</h3>${driveRows}</div>
    <div class="source-section"><h3>Favorites</h3>${state.specials.map(folderRow).join('')}</div>
    ${state.recents.length ? `<div class="source-section"><h3>Folders</h3>${state.recents.map(folderRow).join('')}</div>` : ''}`;
}

// ---------------------------------------------------------------- Overview

const overviewState = { pinned: null, hovered: null };

function renderOverview(source, session) {
  const drive = source.drive;
  setTitle(source.name, drive ? `${Format.bytes(drive.free)} available of ${Format.bytes(drive.total)}` : source.path);
  const failed = session?.status === 'failed' ? `<p class="capacity-detail" style="color:var(--danger)">${esc(session.error)}</p>` : '';
  $('#view').innerHTML = `
    <div class="overview">
      <div class="overview-header">
        <div class="big-icon">${icon(drive ? 'drive' : source.icon || 'folder', 84)}</div>
        <h1>${esc(source.name)}</h1>
        <p>${esc(source.path)}</p>
      </div>
      ${drive ? '<div class="card capacity-card" id="capacity"></div>' : ''}
      <div class="actions">
        <button class="button primary large" id="scanNow">${icon('pie')}Scan</button>
        <button class="button large square" id="revealSource" title="Show in ${esc(state.info.fileManager)}">${icon('folder')}</button>
      </div>
      ${failed}
      ${isMacLike() ? `<div class="card notice">${icon('shield', 26).replace('class="icon"', 'class="icon notice-icon"')}
        <div><h4>Full Disk Access</h4><p>Without it, protected folders like Mail, Messages and Safari data can't be measured.</p></div>
        <button class="button" id="privacy">Open Settings</button></div>` : ''}
    </div>`;
  if (drive) renderCapacity(drive);
  $('#scanNow').onclick = () => startScan(source.key);
  $('#revealSource').onclick = () => api.reveal(source.path);
  const privacy = $('#privacy');
  if (privacy) privacy.onclick = () => api.openPrivacySettings();
}

function renderCapacity(drive) {
  const slices = [
    { key: 'used', name: 'Used', value: drive.used, color: 'var(--accent)' },
    { key: 'free', name: 'Free', value: drive.free, color: 'rgba(127,127,127,0.28)' },
  ].filter((s) => s.value > 0);
  const total = slices.reduce((sum, s) => sum + s.value, 0);
  const shown = overviewState.hovered || overviewState.pinned;
  const radius = 76;
  const circumference = 2 * Math.PI * radius;
  let offset = 0;
  const arcs = slices.map((s) => {
    const length = (s.value / total) * circumference;
    const gap = slices.length > 1 ? 3 : 0;
    const arc = `<circle class="arc" data-key="${s.key}" cx="95" cy="95" r="${radius}" fill="none" stroke="${s.color}" stroke-width="30"
      stroke-dasharray="${Math.max(0, length - gap)} ${circumference}" stroke-dashoffset="${-offset}"
      opacity="${!shown || shown === s.key ? 1 : 0.35}"/>`;
    offset += length;
    return arc;
  }).join('');
  const shownSlice = slices.find((s) => s.key === shown);
  const center = shownSlice
    ? `<div class="value tabular">${Format.bytes(shownSlice.value)}</div><div class="label">${shownSlice.name.toLowerCase()}</div>`
    : `<div class="value">${Math.round((drive.used / drive.total) * 100)}%</div><div class="label">used</div>`;
  const legend = slices.map((s) => `<button class="legend-row ${overviewState.pinned === s.key ? 'pinned' : ''} ${overviewState.hovered === s.key ? 'hovered' : ''}" data-key="${s.key}">
      <span class="swatch" style="background:${s.color}"></span><span class="name">${s.name}</span>
      <span class="value tabular">${Format.bytes(s.value)}</span>${icon(overviewState.pinned === s.key ? 'chevronDown' : 'chevronRight', 14).replace('class="icon"', 'class="icon chev"')}</button>`).join('');
  const details = {
    used: 'Files, apps and the system on this drive. Scan it to see exactly what takes up the space, then collect what you don\'t need.',
    free: 'Empty space, ready to use.',
  };
  const card = $('#capacity');
  card.innerHTML = `
    <div class="capacity-row">
      <div class="donut"><svg viewBox="0 0 190 190">${arcs}</svg><div class="donut-center">${center}</div></div>
      <div class="legend">${legend}<div class="divider"></div>
        <div class="total"><span>Capacity</span><span class="tabular">${Format.bytes(drive.total)}</span></div></div>
    </div>
    ${overviewState.pinned ? `<div class="capacity-detail">${details[overviewState.pinned]}</div>` : ''}`;
  const pin = (key) => { overviewState.pinned = overviewState.pinned === key ? null : key; renderCapacity(drive); };
  const hover = (key) => { if (overviewState.hovered !== key) { overviewState.hovered = key; renderCapacity(drive); } };
  for (const el of card.querySelectorAll('[data-key]')) {
    el.onclick = () => pin(el.dataset.key);
    el.onmouseenter = () => hover(el.dataset.key);
    el.onmouseleave = () => hover(null);
  }
}

// ---------------------------------------------------------------- Scanning view

let scanAnimation = null;

function renderScanning(session) {
  setTitle(session.source.name, 'Scanning');
  $('#view').innerHTML = `
    <div class="scanning">
      <div class="scan-hero"><canvas id="scanRings" width="560" height="560"></canvas>
        <div class="scan-disc"><div class="number tabular" id="scanNumber">0</div><div class="unit" id="scanUnit">bytes</div>
          <div class="files tabular" id="scanFiles">0 files</div></div></div>
      <div class="scan-text"><h2>Scanning “${esc(session.source.name)}”…</h2>
        <div class="path"><span dir="ltr" id="scanPath"></span></div><div class="elapsed tabular" id="scanElapsed"></div></div>
      <button class="button large" id="cancelScan">Cancel Scanning</button>
    </div>`;
  $('#cancelScan').onclick = () => session.id && api.cancelScan(session.id);
  updateScanning(session);
  cancelAnimationFrame(scanAnimation);
  const canvas = $('#scanRings');
  const ctx = canvas.getContext('2d');
  const tick = () => {
    if (!document.body.contains(canvas)) return;
    const t = performance.now() / 1000;
    const size = canvas.width;
    const center = size / 2;
    const line = size * 0.048;
    const gap = size * 0.076;
    ctx.clearRect(0, 0, size, size);
    ctx.lineCap = 'round';
    for (let i = 0; i < 3; i++) {
      const radius = size / 2 - i * gap - line * 0.7;
      const start = (t * (0.6 + i * 0.35) + i * 0.9) % (Math.PI * 2);
      const sweep = 1.4 + Math.sin(t * 1.3 + i) * 0.7;
      ctx.beginPath(); ctx.arc(center, center, radius, 0, Math.PI * 2);
      ctx.strokeStyle = 'rgba(127,127,127,0.12)'; ctx.lineWidth = line; ctx.stroke();
      ctx.beginPath(); ctx.arc(center, center, radius, start, start + sweep);
      const hue = ((t * 0.05 + i * 0.18) % 1) * 360;
      ctx.strokeStyle = `hsl(${hue}, 80%, 62%)`; ctx.stroke();
    }
    scanAnimation = requestAnimationFrame(tick);
  };
  tick();
}

function updateScanning(session) {
  const number = $('#scanNumber');
  if (!number) return;
  const steady = Format.steady(session.progress.bytes || 0);
  number.textContent = steady.number;
  $('#scanUnit').textContent = steady.unit;
  $('#scanFiles').textContent = `${Format.count(session.progress.files || 0)} files`;
  $('#scanPath').textContent = session.progress.current || '';
  $('#scanElapsed').textContent = Format.duration((Date.now() - session.startedAt) / 1000);
}
setInterval(() => {
  const session = state.sessions.get(state.selectedKey);
  if (session?.status === 'scanning') updateScanning(session);
}, 500);

// ---------------------------------------------------------------- Report

function renderReport(session) {
  if (state.reportKey !== session.key) {
    state.reportKey = session.key;
    $('#view').innerHTML = `
      <div class="report">
        <div class="map-pane" id="mapPane">
          <div class="map-top">
            <div class="pathbar-row"><div class="pathbar" id="pathbar"></div>
              <button class="button" id="cleanupButton">${icon('sparkles')}Clean Up</button></div>
            <div id="bannerSlot"></div>
          </div>
          <div class="map" id="map"><canvas id="canvas" draggable="true"></canvas><div class="center-disc" id="centerDisc"></div></div>
          <div class="collector-space"></div>
          <div class="collector" id="collector"></div>
          <div id="toastSlot"></div>
        </div>
        <div class="list-pane" id="listPane"><div class="list-scroll" id="listScroll"><div class="list-content" id="listContent"></div></div></div>
      </div>`;
    wireReport(session);
  }
  updateReport(session);
}

function updateReport(session, { animate = false } = {}) {
  if (state.reportKey !== session.key || !session.view) return;
  const view = session.view;
  const pending = collectedSize(session);
  const parts = [`${Format.bytes(view.rootSize - pending)} used`];
  if (session.source.isDrive && session.capacity) parts.push(`${Format.bytes(session.capacity.free + pending)} free`);
  parts.push(`${Format.count(view.rootFiles)} files`);
  if (pending > 0) parts.push(`after freeing ${Format.bytes(pending)}`);
  setTitle(session.source.name, parts.join(' · '));
  renderToolbar(session);
  renderPathbar(session);
  renderBanner(session);
  renderList(session);
  renderCollector(session);
  renderToast(session);
  layoutPanes(session);
  if (animate) {
    const map = $('#map');
    map.animate([{ transform: 'scale(0.9)', opacity: 0 }, { transform: 'scale(1)', opacity: 1 }],
      { duration: 320, easing: 'cubic-bezier(0.2, 0.9, 0.25, 1)' });
  }
  drawMap(session);
}

function renderToolbar(session) {
  $('#toolbar').innerHTML = `
    <div class="button-group">
      <button class="icon-button" id="back" title="Back" ${session.back.length ? '' : 'disabled'}>${icon('back')}</button>
      <button class="icon-button" id="forward" title="Forward" ${session.forward.length ? '' : 'disabled'}>${icon('forward')}</button>
    </div>
    <div class="button-group">
      <button class="icon-button" id="rescan" title="Rescan">${icon('refresh')}</button>
      <button class="icon-button" id="moreMenu" title="More">${icon('more')}</button>
    </div>
    <button class="icon-button" id="toggleList" title="Show or hide the contents list" ${listFits() ? '' : 'disabled'}>${icon('list')}</button>`;
  $('#back').onclick = () => goBack(session);
  $('#forward').onclick = () => goForward(session);
  $('#rescan').onclick = () => startScan(session.key);
  $('#toggleList').onclick = () => { state.listVisible = !state.listVisible; layoutPanes(session); drawMap(session); };
  $('#moreMenu').onclick = async () => {
    const choice = await api.contextMenu([
      { id: 'csv', label: 'Export to CSV…' },
      { id: 'reveal', label: `Show in ${state.info.fileManager}` },
      { separator: true },
      { id: 'forget', label: 'Forget Scan Result' },
    ]);
    if (choice === 'csv') api.exportCSV(session.id, session.focus, session.view.node.name);
    else if (choice === 'reveal') api.reveal(session.view.path);
    else if (choice === 'forget') forget(session.key);
  };
}

function forget(key) {
  const session = state.sessions.get(key);
  if (session?.id) api.forgetScan(session.id);
  state.sessions.delete(key);
  state.reportKey = null;
  render();
}

function renderPathbar(session) {
  const lineage = session.view.lineage;
  const tail = lineage.slice(-4);
  const hiddenCount = lineage.length - tail.length;
  const crumbs = [];
  if (hiddenCount > 0) crumbs.push(`<button class="crumb" data-crumb="more" title="More">${icon('more', 16)}</button><span class="crumb-sep">${icon('chevronRight', 12)}</span>`);
  tail.forEach((node, index) => {
    if (index > 0) crumbs.push(`<span class="crumb-sep">${icon('chevronRight', 12)}</span>`);
    const current = index === tail.length - 1;
    crumbs.push(`<button class="crumb ${current ? 'current' : ''}" data-crumb="${node.id}" title="${esc(node.name)}">
      ${icon(index === 0 && hiddenCount === 0 && session.source.isDrive ? 'drive' : 'folder', 15)}<span>${esc(node.name)}</span></button>`);
  });
  const focus = session.view.node;
  crumbs.push(`<span class="size tabular">${Format.bytes(remaining(session, focus.id, focus.size))}</span>`);
  const bar = $('#pathbar');
  bar.innerHTML = crumbs.join('');
  for (const crumb of bar.querySelectorAll('[data-crumb]')) {
    crumb.onclick = async () => {
      if (crumb.dataset.crumb === 'more') {
        const choice = await api.contextMenu(lineage.slice(0, hiddenCount).reverse().map((n) => ({ id: String(n.id), label: n.name })));
        if (choice) navigate(session, Number(choice));
      } else {
        navigate(session, Number(crumb.dataset.crumb));
      }
    };
  }
}

function renderBanner(session) {
  const slot = $('#bannerSlot');
  if (!session.restricted || session.bannerDismissed) { slot.innerHTML = ''; return; }
  const hint = isMacLike()
    ? 'Grant Full Disk Access to include protected folders.'
    : 'Run Disk Cleaner Free as administrator to include them.';
  slot.innerHTML = `<div class="banner">${icon('lock', 16)}<span class="grow">${Format.count(session.restricted)} folders couldn't be read. ${hint}</span>
    ${isMacLike() ? '<button class="button" id="bannerSettings">Open Settings</button>' : ''}
    <button class="icon-button" id="bannerClose" title="Dismiss">${icon('x', 14)}</button></div>`;
  $('#bannerClose').onclick = () => { session.bannerDismissed = true; renderBanner(session); };
  const settings = $('#bannerSettings');
  if (settings) settings.onclick = () => api.openPrivacySettings();
}

// ---- Map

let mapGeometry = null;

function drawMap(session) {
  const canvas = $('#canvas');
  if (!canvas || !session.model) return;
  const rect = canvas.getBoundingClientRect();
  const ratio = window.devicePixelRatio || 1;
  if (canvas.width !== Math.round(rect.width * ratio) || canvas.height !== Math.round(rect.height * ratio)) {
    canvas.width = Math.round(rect.width * ratio);
    canvas.height = Math.round(rect.height * ratio);
  }
  const ctx = canvas.getContext('2d');
  ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
  ctx.clearRect(0, 0, rect.width, rect.height);
  mapGeometry = Sunburst.geometry(rect.width, rect.height, DEPTH);
  const parents = session.model.parents;
  const insideHovered = (id) => {
    for (let current = id; current !== null && current !== undefined; current = parents.get(current)) {
      if (current === session.hovered) return true;
    }
    return false;
  };
  const stroke = getComputedStyle(document.documentElement).getPropertyValue('--segment-stroke').trim() || '#17171e';
  Sunburst.draw(ctx, session.model, mapGeometry, {
    hovered: session.hovered,
    isHoveredOrInside: (id) => session.hovered !== null && insideHovered(id),
    isSelected: (id) => session.selection.has(id),
    isCollected: (id) => insideCollected(session, id),
    stroke,
  });
  renderCenter(session);
}

function renderCenter(session) {
  const disc = $('#centerDisc');
  if (!disc || !mapGeometry) return;
  const diameter = mapGeometry.inner * 2 - 10;
  const side = diameter * 0.7;
  Object.assign(disc.style, {
    width: `${diameter}px`, height: `${diameter}px`,
    left: `${mapGeometry.center.x - diameter / 2}px`, top: `${mapGeometry.center.y - diameter / 2}px`,
  });
  const hoveredSegment = session.model.segments.find((s) => s.id === session.hovered);
  const node = hoveredSegment ? { id: hoveredSegment.id, name: hoveredSegment.name, size: hoveredSegment.size } : session.view.node;
  const value = Format.steady(remaining(session, node.id, node.size));
  disc.innerHTML = `
    <div class="name" style="font-size:${Math.max(9, side * 0.12)}px;width:${side}px;height:${side * 0.2}px;line-height:${side * 0.2}px">${esc(node.name)}</div>
    <div class="number tabular" style="font-size:${Math.max(12, side * 0.3)}px;line-height:${side * 0.36}px">${value.number}</div>
    <div class="unit" style="font-size:${Math.max(9, side * 0.13)}px;line-height:${side * 0.2}px">${value.unit}</div>`;
}

function setHovered(session, id) {
  if (session.hovered === id) return;
  session.hovered = id;
  for (const row of document.querySelectorAll('.row.hovered')) row.classList.remove('hovered');
  if (id !== null) document.querySelector(`.row[data-id="${id}"]`)?.classList.add('hovered');
  drawMap(session);
}

function wireReport(session) {
  const canvas = $('#canvas');
  const map = $('#map');
  new ResizeObserver(() => { layoutPanes(session); drawMap(session); }).observe($('#mapPane'));

  canvas.addEventListener('mousemove', (event) => {
    const rect = canvas.getBoundingClientRect();
    const result = mapGeometry && Sunburst.hit(session.model, mapGeometry, event.clientX - rect.left, event.clientY - rect.top);
    setHovered(session, result?.segment ? result.segment.id : null);
    canvas.style.cursor = result?.segment?.hasChildren || result?.center ? 'pointer' : 'default';
  });
  canvas.addEventListener('mouseleave', () => setHovered(session, null));
  canvas.addEventListener('click', (event) => {
    const rect = canvas.getBoundingClientRect();
    const result = mapGeometry && Sunburst.hit(session.model, mapGeometry, event.clientX - rect.left, event.clientY - rect.top);
    if (!result) return;
    if (result.center) { goUp(session); return; }
    const segment = result.segment;
    if (segment.hasChildren) navigate(session, segment.id);
    else if (segment.kind !== KIND.HIDDEN) { session.selection = new Map([[segment.id, true]]); session.anchor = segment.id; refreshSelection(session); }
  });
  canvas.addEventListener('contextmenu', (event) => {
    event.preventDefault();
    if (session.hovered !== null) nodeMenu(session, session.hovered);
  });
  canvas.addEventListener('dragstart', (event) => {
    const segment = session.model.segments.find((s) => s.id === session.hovered);
    if (!segment || segment.kind === KIND.HIDDEN) { event.preventDefault(); return; }
    startDrag(event, session, segment.id, segment.name);
  });

  $('#cleanupButton').onclick = () => openCleanup(session);

  const list = $('#listContent');
  list.addEventListener('mouseover', (event) => {
    const row = event.target.closest('.row[data-id]');
    if (row) setHovered(session, Number(row.dataset.id));
  });
  list.addEventListener('mouseleave', () => setHovered(session, null));
  list.addEventListener('click', (event) => {
    const row = event.target.closest('.row[data-id]');
    if (row) clickRow(session, Number(row.dataset.id), event);
    else if (event.target.closest('[data-action="expand"]')) {
      session.expandedList = true;
      api.tree(session.id, 'children', { id: session.focus }).then((all) => { session.allChildren = all; renderList(session); });
    }
  });
  list.addEventListener('contextmenu', (event) => {
    const row = event.target.closest('.row[data-id]');
    if (!row) return;
    event.preventDefault();
    nodeMenu(session, Number(row.dataset.id));
  });
  list.addEventListener('dragstart', (event) => {
    const row = event.target.closest('.row[data-id]');
    if (!row) return;
    startDrag(event, session, Number(row.dataset.id), row.querySelector('.name')?.textContent || '');
  });
  list.addEventListener('mousedown', (event) => startBand(event, session));

  wireCollector(session);
}

function startDrag(event, session, id, name) {
  const ids = session.selection.has(id) ? [...session.selection.keys()] : [id];
  event.dataTransfer.setData('application/x-dcf-ids', JSON.stringify(ids));
  event.dataTransfer.effectAllowed = 'copy';
  const ghost = document.createElement('div');
  ghost.className = 'pill';
  ghost.style.cssText = 'position:fixed;top:-100px;left:-100px;background:var(--surface-strong)';
  ghost.textContent = ids.length > 1 ? `${ids.length} items` : name;
  document.body.appendChild(ghost);
  event.dataTransfer.setDragImage(ghost, 16, 16);
  setTimeout(() => ghost.remove(), 0);
}

// ---- Rubber-band selection

function startBand(event, session) {
  if (event.button !== 0 || event.target.closest('.row[data-id]') || event.target.closest('[data-action]')) return;
  const content = $('#listContent');
  const origin = content.getBoundingClientRect();
  const start = { x: event.clientX - origin.left, y: event.clientY - origin.top };
  const base = primaryModifier(event) || event.shiftKey ? new Map(session.selection) : new Map();
  let band = null;
  const move = (e) => {
    const box = content.getBoundingClientRect();
    const current = { x: e.clientX - box.left, y: e.clientY - box.top };
    if (!band && Math.hypot(current.x - start.x, current.y - start.y) < 4) return;
    if (!band) { band = document.createElement('div'); band.className = 'band'; content.appendChild(band); }
    const rect = { left: Math.min(start.x, current.x), top: Math.min(start.y, current.y),
      right: Math.max(start.x, current.x), bottom: Math.max(start.y, current.y) };
    Object.assign(band.style, { left: `${rect.left}px`, top: `${rect.top}px`, width: `${rect.right - rect.left}px`, height: `${rect.bottom - rect.top}px` });
    const selection = new Map(base);
    for (const row of content.querySelectorAll('.row[data-id]')) {
      if (row.dataset.kind === String(KIND.HIDDEN)) continue;
      const r = row.getBoundingClientRect();
      const top = r.top - box.top;
      const bottom = r.bottom - box.top;
      const left = r.left - box.left;
      const right = r.right - box.left;
      if (left < rect.right && right > rect.left && top < rect.bottom && bottom > rect.top) selection.set(Number(row.dataset.id), true);
    }
    session.selection = selection;
    refreshSelection(session);
  };
  const up = () => {
    window.removeEventListener('mousemove', move);
    window.removeEventListener('mouseup', up);
    if (band) band.remove(); else { session.selection.clear(); refreshSelection(session); }
  };
  window.addEventListener('mousemove', move);
  window.addEventListener('mouseup', up);
}

// ---- List

function listFits() {
  return ($('.content')?.clientWidth || window.innerWidth) >= 600;
}

function layoutPanes(session) {
  const pane = $('#listPane');
  if (!pane) return;
  const width = $('.content').clientWidth;
  const show = state.listVisible && listFits();
  pane.classList.toggle('hidden', !show);
  pane.style.width = `${Math.min(420, Math.max(260, width * 0.42))}px`;
  const toggle = $('#toggleList');
  if (toggle) toggle.disabled = !listFits();
  const collector = $('#collector');
  if (collector) collector.style.height = session.drawerOpen ? `${Math.max(220, $('#mapPane').clientHeight * 0.5) + 58}px` : '60px';
}

function renderList(session) {
  const content = $('#listContent');
  if (!content) return;
  const view = session.view;
  const focus = view.node;
  const pending = session.within.get(focus.id) && !session.collected.has(focus.id) ? session.within.get(focus.id) : 0;
  const rows = session.allChildren || view.list;
  const colors = session.model.colors;
  const rowHtml = (node) => {
    const collected = insideCollected(session, node.id);
    const size = collected && session.collected.has(node.id) ? node.size : remaining(session, node.id, node.size);
    const special = node.kind === KIND.HIDDEN;
    const dot = colors.get(node.id) || 'rgba(127,127,127,0.4)';
    const name = special ? `${node.name.toLowerCase()}…` : node.name;
    const title = special
      ? 'Space in use that no scanned file accounts for: system files, other users\' folders and folders that need administrator rights.'
      : '';
    return `<div class="row ${collected ? 'collected' : ''} ${session.selection.has(node.id) ? 'selected' : ''} ${session.hovered === node.id ? 'hovered' : ''} ${special ? 'special' : ''}"
      data-id="${node.id}" data-kind="${node.kind}" ${special ? '' : 'draggable="true"'} title="${esc(title)}" ${special ? `style="color:${dot}"` : ''}>
      <span class="dot" style="background:${dot}"></span><span class="name">${esc(name)}</span><span class="size tabular">${Format.bytes(size)}</span></div>`;
  };
  const rest = !session.allChildren && view.rest.count > 0
    ? `<div class="row dim" data-action="expand" title="Show ${Format.count(view.rest.count)} more items">
        <span class="dot" style="background:rgba(127,127,127,0.35)"></span><span class="name">smaller objects…</span>
        <span class="size tabular">${Format.bytes(view.rest.size)}</span></div>` : '';
  const freeRows = focus.id === 0 && session.source.isDrive && session.capacity
    ? `<div class="list-divider"></div><div class="row dim"><span class="dot" style="background:rgba(127,127,127,0.35)"></span>
        <span class="name">free space</span><span class="size tabular">${Format.bytes(session.capacity.free)}</span></div>` : '';
  content.innerHTML = `
    <div class="list-header"><span class="name">${esc(focus.name)}</span><span class="tabular">${Format.bytes(focus.size - pending)}</span></div>
    ${pending > 0 ? `<div class="list-pending tabular">${Format.bytes(pending)} collected for deletion</div>` : ''}
    <div class="list-gap"></div>
    ${rows.map(rowHtml).join('')}${rest}
    ${rows.length ? '' : '<div class="row dim"><span class="name">This folder is empty</span></div>'}
    ${freeRows}`;
}

// ---- Collector

function wireCollector(session) {
  const collector = $('#collector');
  collector.addEventListener('dragover', (event) => {
    event.preventDefault();
    event.dataTransfer.dropEffect = 'copy';
    collector.classList.add('targeted');
  });
  collector.addEventListener('dragleave', (event) => {
    if (!collector.contains(event.relatedTarget)) collector.classList.remove('targeted');
  });
  collector.addEventListener('drop', async (event) => {
    event.preventDefault();
    collector.classList.remove('targeted');
    const ids = event.dataTransfer.getData('application/x-dcf-ids');
    if (ids) { collect(session, JSON.parse(ids)); return; }
    const paths = [...event.dataTransfer.files].map((file) => api.pathForFile(file)).filter(Boolean);
    if (paths.length) collect(session, (await api.tree(session.id, 'find', { paths })).filter((id) => id >= 0));
  });
}

function renderCollector(session) {
  const collector = $('#collector');
  if (!collector) return;
  const items = [...session.collected.values()].sort((a, b) => b.size - a.size);
  const total = collectedSize(session);
  const has = items.length > 0;
  collector.classList.toggle('has-items', has);
  collector.classList.toggle('expanded', session.drawerOpen);
  const list = session.drawerOpen ? `
    <div class="collector-list">
      <header><h3>To be moved to the ${esc(state.info.bin)}</h3><span class="tabular">${Format.count(items.length)} items · ${Format.bytes(total)}</span></header>
      ${has ? `<div class="collector-items">${items.map((item) => `
        <div class="collected-row" data-id="${item.id}" title="${esc(item.path)}">
          <img data-icon-path="${esc(item.path)}" alt="">
          <div class="main"><div class="name">${esc(item.name)}</div><div class="where"><span dir="ltr">${esc(item.path.slice(0, Math.max(0, item.path.length - item.name.length - 1)))}</span></div></div>
          <span class="size tabular">${Format.bytes(item.size)}</span>
          <button class="icon-button" data-act="reveal" title="Show in ${esc(state.info.fileManager)}">${icon('reveal', 16)}</button>
          <button class="icon-button" data-act="remove" title="Keep this item: remove it from the Collector">${icon('xCircle', 16)}</button>
        </div>`).join('')}</div>`
    : `<div class="empty-state">${icon('tray', 36)}<strong>Nothing collected yet</strong>Drag files and folders from the map or the list onto this bar.</div>`}
    </div>` : '';
  const actions = !has ? `<span class="collector-hint">Drag files and folders here to collect them for deletion</span>`
    : session.deleting ? `<span class="spacer"></span><span class="spinner"></span><span style="color:var(--text-2)">Moving to the ${esc(state.info.bin)}…</span>`
      : `<span class="spacer"></span>
         <button class="pill" id="clearCollector" title="Remove everything from the Collector without deleting it">${icon('x', 15)}Clear</button>
         <button class="button danger" id="trashCollected">${icon('trash', 16)}Move to ${esc(state.info.bin)}</button>`;
  collector.innerHTML = `${list}
    <div class="collector-bar">
      <button class="drawer-handle" id="drawerHandle" title="${session.drawerOpen ? 'Close the list of collected items' : 'Review everything collected for deletion'}">
        ${icon(has ? 'trayFull' : 'tray', 22)}
        ${has ? `<span class="totals"><strong class="tabular">${Format.bytes(total)}</strong><small>${Format.count(items.length)} item${items.length === 1 ? '' : 's'} collected</small></span>` : ''}
        ${icon('chevronUp', 16).replace('class="icon"', 'class="icon chev"')}
      </button>
      ${actions}
    </div>`;
  $('#drawerHandle').onclick = () => { session.drawerOpen = !session.drawerOpen; renderCollector(session); layoutPanes(session); };
  const clear = $('#clearCollector');
  if (clear) clear.onclick = () => clearCollector(session);
  const trash = $('#trashCollected');
  if (trash) trash.onclick = () => trashCollected(session);
  for (const row of collector.querySelectorAll('.collected-row')) {
    const id = Number(row.dataset.id);
    row.querySelector('[data-act="reveal"]').onclick = (e) => { e.stopPropagation(); api.reveal(session.collected.get(id).path); };
    row.querySelector('[data-act="remove"]').onclick = (e) => { e.stopPropagation(); uncollect(session, id); };
    row.onmouseenter = () => setHovered(session, id);
    row.onmouseleave = () => setHovered(session, null);
  }
  for (const img of collector.querySelectorAll('img[data-icon-path]')) {
    api.fileIcon(img.dataset.iconPath).then((url) => { if (url) img.src = url; else img.remove(); });
  }
}

function renderToast(session) {
  const slot = $('#toastSlot');
  if (!slot) return;
  const toast = session.toast;
  if (!toast) { slot.innerHTML = ''; return; }
  slot.innerHTML = `<div class="toast">${toast.freed > 0 ? `Moved ${Format.bytes(toast.freed)} to the ${esc(state.info.bin)}` : 'Nothing was moved'}
    <small>${toast.freed > 0 ? `Empty the ${esc(state.info.bin)} to reclaim the space.` : ''}${toast.failed ? ` ${toast.failed} items couldn't be moved.` : ''}</small></div>`;
}

// ---------------------------------------------------------------- Clean Up

async function openCleanup(session) {
  const modal = $('#modal');
  modal.classList.remove('hidden');
  modal.innerHTML = '<div class="sheet"><header><div><h2>Clean Up</h2><p>Looking for caches…</p></div></header></div>';
  const categories = await api.cleanup(session.id);
  const chosen = new Set(categories.filter((c) => c.selectedByDefault).map((c) => c.id));
  const expanded = new Set();
  const close = () => { modal.classList.add('hidden'); modal.innerHTML = ''; };
  const draw = () => {
    const total = categories.filter((c) => chosen.has(c.id)).reduce((sum, c) => sum + c.items.reduce((s, i) => s + i.size, 0), 0);
    modal.innerHTML = `
      <div class="sheet" role="dialog" aria-label="Clean Up">
        <header>${icon('sparkles', 28)}<div><h2>Clean Up Caches</h2>
          <p>Pick what to collect. Nothing is deleted until you review the Collector and click Move to ${esc(state.info.bin)}.</p></div></header>
        <div class="sheet-body">
          ${categories.length ? categories.map((c) => {
            const size = c.items.reduce((s, i) => s + i.size, 0);
            return `<div class="category ${chosen.has(c.id) ? 'chosen' : ''}">
              <div class="head"><label><input type="checkbox" data-category="${c.id}" ${chosen.has(c.id) ? 'checked' : ''}>${esc(c.title)}</label>
                <span class="safety ${c.safety}">${c.safety === 'safe' ? 'Safe' : 'Use care'}</span><span class="size tabular">${Format.bytes(size)}</span></div>
              <p>${esc(c.detail)}</p>
              <button class="link" data-expand="${c.id}">${expanded.has(c.id) ? 'Hide items' : `Show ${c.items.length} item${c.items.length === 1 ? '' : 's'}`}</button>
              ${expanded.has(c.id) ? `<div class="items">${c.items.slice().sort((a, b) => b.size - a.size).slice(0, 60)
                .map((i) => `<div title="${esc(i.path)}"><span>${esc(i.name)}</span><span class="tabular">${Format.bytes(i.size)}</span></div>`).join('')}</div>` : ''}
            </div>`;
          }).join('') : `<div class="empty-state">${icon('check', 36)}<strong>No caches found</strong>There's nothing to clean up in the scanned folders.</div>`}
        </div>
        <footer><div class="total"><strong class="tabular">${Format.bytes(total)}</strong><small>selected</small></div>
          <button class="button" id="cleanupCancel">Cancel</button>
          <button class="button danger" id="cleanupCollect" ${total ? '' : 'disabled'}>${icon('trayFull', 16)}Add to Collector</button></footer>
      </div>`;
    for (const box of modal.querySelectorAll('[data-category]')) {
      box.onchange = () => { if (box.checked) chosen.add(box.dataset.category); else chosen.delete(box.dataset.category); draw(); };
    }
    for (const link of modal.querySelectorAll('[data-expand]')) {
      link.onclick = () => { const id = link.dataset.expand; if (expanded.has(id)) expanded.delete(id); else expanded.add(id); draw(); };
    }
    $('#cleanupCancel').onclick = close;
    $('#cleanupCollect').onclick = () => {
      const ids = categories.filter((c) => chosen.has(c.id)).flatMap((c) => c.items.map((i) => i.id));
      close();
      collect(session, ids);
    };
  };
  modal.onclick = (event) => { if (event.target === modal) close(); };
  draw();
}

// ---------------------------------------------------------------- Window chrome & input

function applySidebar() {
  $('.app').classList.toggle('sidebar-hidden', state.sidebarHidden);
  $('#showSidebar').classList.toggle('hidden', !state.sidebarHidden);
}

function adaptToWidth() {
  const width = window.innerWidth;
  if (width < 900 && !state.sidebarHidden) { state.sidebarHidden = true; state.sidebarAutoHidden = true; applySidebar(); }
  else if (width >= 920 && state.sidebarAutoHidden) { state.sidebarHidden = false; state.sidebarAutoHidden = false; applySidebar(); }
  const session = state.sessions.get(state.selectedKey);
  if (session && state.reportKey === session.key) { layoutPanes(session); drawMap(session); }
}

document.addEventListener('keydown', (event) => {
  const modal = $('#modal');
  if (!modal.classList.contains('hidden')) {
    if (event.key === 'Escape') { modal.classList.add('hidden'); modal.innerHTML = ''; }
    return;
  }
  const session = state.sessions.get(state.selectedKey);
  if (!session || session.status !== 'done') return;
  const mod = primaryModifier(event);
  if ((event.altKey && event.key === 'ArrowLeft') || (mod && event.key === '[')) { event.preventDefault(); goBack(session); }
  else if ((event.altKey && event.key === 'ArrowRight') || (mod && event.key === ']')) { event.preventDefault(); goForward(session); }
  else if (event.key === 'Escape' || (event.altKey && event.key === 'ArrowUp')) { event.preventDefault(); goUp(session); }
  else if (mod && event.key.toLowerCase() === 'a') {
    event.preventDefault();
    session.selection = new Map(rowOrder(session).filter((id) => findListNode(session, id)?.kind !== KIND.HIDDEN).map((id) => [id, true]));
    refreshSelection(session);
  } else if (event.key === 'Delete' || (isMacLike() && mod && event.key === 'Backspace') || (mod && event.key.toLowerCase() === 'k')) {
    event.preventDefault();
    collect(session, [...session.selection.keys()]);
  } else if (event.key === 'Enter' && session.selection.size === 1) {
    const node = findListNode(session, [...session.selection.keys()][0]);
    if (node) openNode(session, node);
  } else if (event.key === 'F5' || (mod && event.key.toLowerCase() === 'r')) {
    event.preventDefault();
    startScan(session.key);
  }
});

// Drop a folder anywhere outside the Collector to scan it.
document.addEventListener('dragover', (event) => { if (event.dataTransfer.types.includes('Files')) event.preventDefault(); });
document.addEventListener('drop', (event) => {
  if (event.target.closest?.('#collector')) return;
  event.preventDefault();
  const file = event.dataTransfer.files[0];
  const target = file && api.pathForFile(file);
  if (target) openFolder(target);
});

$('#sources').addEventListener('click', (event) => {
  const row = event.target.closest('.source[data-key]');
  if (row) select(row.dataset.key);
});
$('#sources').addEventListener('contextmenu', async (event) => {
  const row = event.target.closest('.source[data-key]');
  if (!row) return;
  event.preventDefault();
  const key = row.dataset.key;
  const session = state.sessions.get(key);
  const isRecent = state.recents.some((r) => r.path === key);
  const choice = await api.contextMenu([
    session?.status === 'scanning' ? { id: 'cancel', label: 'Cancel Scanning' } : { id: 'scan', label: session ? 'Rescan' : 'Scan' },
    { id: 'reveal', label: `Show in ${state.info.fileManager}` },
    ...(session?.status === 'done' ? [{ id: 'forget', label: 'Forget Scan Result' }] : []),
    ...(isRecent ? [{ separator: true }, { id: 'remove', label: 'Remove from List' }] : []),
  ]);
  if (choice === 'scan') { select(key); startScan(key); }
  else if (choice === 'cancel') api.cancelScan(session.id);
  else if (choice === 'reveal') api.reveal(key);
  else if (choice === 'forget') forget(key);
  else if (choice === 'remove') {
    forget(key);
    state.recents = state.recents.filter((r) => r.path !== key);
    if (state.selectedKey === key) state.selectedKey = state.drives[0]?.path || null;
    render();
  }
});
$('#scanFolder').onclick = async () => { const folder = await api.chooseFolder(); if (folder) openFolder(folder); };
$('#toggleSidebar').onclick = () => { state.sidebarHidden = true; state.sidebarAutoHidden = false; applySidebar(); adaptToWidth(); };
$('#showSidebar').onclick = () => { state.sidebarHidden = false; state.sidebarAutoHidden = false; applySidebar(); adaptToWidth(); };
window.addEventListener('resize', adaptToWidth);
window.addEventListener('focus', refreshDrives);
api.onThemeChanged(() => {
  const session = state.sessions.get(state.selectedKey);
  if (session && state.reportKey === session.key) drawMap(session);
});

// ---------------------------------------------------------------- Start

(async () => {
  state.info = await api.platformInfo();
  document.documentElement.classList.add(`platform-${state.info.platform}`);
  document.documentElement.style.setProperty('--accent', state.info.accent);
  Format.setBinary(state.info.platform === 'win32');
  hydrateIcons();
  [state.drives, state.specials] = await Promise.all([api.drives(), api.specialFolders()]);
  state.selectedKey = state.drives[0]?.path || null;
  adaptToWidth();
  render();
  for (const folder of await api.launchFolders()) openFolder(folder);
})();
