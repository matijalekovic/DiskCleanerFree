// Scans one disk or folder, then serves queries about the result. One worker per scan session,
// so the window never has to hold millions of entries.
'use strict';

const { parentPort, workerData } = require('worker_threads');
const fs = require('fs');
const path = require('path');

const KIND = { FILE: 0, DIR: 1, LINK: 2, RESTRICTED: 3, HIDDEN: 4 };
const isWindows = process.platform === 'win32';
const sep = path.sep;
const cancelFlag = new Int32Array(workerData.cancelBuffer);

// ---- Tree storage: parallel arrays indexed by node id. A child always has a higher id than its parent.

let capacity = 1 << 16;
let count = 0;
let parent = new Int32Array(capacity);
let size = new Float64Array(capacity);
let fileCount = new Int32Array(capacity);
let kind = new Uint8Array(capacity);
let deleted = new Uint8Array(capacity);
const names = [];
let childStart = null;
let childList = null;

function grow() {
  capacity *= 2;
  const p = new Int32Array(capacity); p.set(parent); parent = p;
  const s = new Float64Array(capacity); s.set(size); size = s;
  const f = new Int32Array(capacity); f.set(fileCount); fileCount = f;
  const k = new Uint8Array(capacity); k.set(kind); kind = k;
  const d = new Uint8Array(capacity); d.set(deleted); deleted = d;
}

function addNode(parentId, name, nodeKind, bytes) {
  if (count === capacity) grow();
  const id = count++;
  parent[id] = parentId;
  size[id] = bytes;
  kind[id] = nodeKind;
  fileCount[id] = nodeKind === KIND.FILE || nodeKind === KIND.LINK ? 1 : 0;
  names.push(name);
  return id;
}

const rootPath = workerData.path;

// ---- Scanning

/** Paths on the macOS system volume that are really other volumes or firmlinks into the data volume. */
function macExclusions() {
  const excluded = new Set(['/System/Volumes', '/Volumes', '/dev', '/private/var/vm']);
  try {
    for (const line of fs.readFileSync('/usr/share/firmlinks', 'utf8').split('\n')) {
      const source = line.split('\t')[0];
      if (source.startsWith('/')) excluded.add(source);
    }
  } catch { /* no firmlinks file */ }
  return excluded;
}

function scan() {
  const excluded = process.platform === 'darwin' && rootPath === '/' ? macExclusions() : new Set();
  const seenInodes = new Set();
  let rootDevice = null;
  try { rootDevice = fs.statSync(rootPath).dev; } catch { /* unreadable root */ }

  const root = addNode(-1, workerData.name, KIND.DIR, 0);
  const stack = [[root, rootPath]];
  let files = 0, bytes = 0, restricted = 0, lastReport = 0, current = rootPath;

  const report = (force) => {
    const now = Date.now();
    if (!force && now - lastReport < 120) return;
    lastReport = now;
    parentPort.postMessage({ type: 'progress', files, bytes, restricted, current });
  };

  while (stack.length) {
    if (Atomics.load(cancelFlag, 0) === 1) return false;
    const [dirId, dirPath] = stack.pop();
    current = dirPath;
    let entries;
    try {
      entries = fs.readdirSync(dirPath, { withFileTypes: true });
    } catch {
      kind[dirId] = KIND.RESTRICTED;
      restricted++;
      continue;
    }
    const base = dirPath.endsWith(sep) ? dirPath : dirPath + sep;
    for (const entry of entries) {
      const entryPath = base + entry.name;
      if (entry.isDirectory()) {
        if (excluded.has(entryPath)) continue;
        if (!isWindows && rootDevice !== null) {
          // Another volume mounted here: list it but don't descend.
          try {
            if (fs.lstatSync(entryPath).dev !== rootDevice) { addNode(dirId, entry.name, KIND.DIR, 0); continue; }
          } catch { /* fall through and try to read it */ }
        }
        stack.push([addNode(dirId, entry.name, KIND.DIR, 0), entryPath]);
      } else if (entry.isSymbolicLink()) {
        addNode(dirId, entry.name, KIND.LINK, 0);
        files++;
      } else {
        let allocated = 0;
        try {
          const st = fs.lstatSync(entryPath);
          // Allocated size where the platform reports blocks; logical size on Windows.
          allocated = !isWindows && st.blocks !== undefined ? st.blocks * 512 : st.size;
          if (!isWindows && st.nlink > 1) {
            const key = st.dev + ':' + st.ino;
            if (seenInodes.has(key)) allocated = 0; else seenInodes.add(key);
          }
        } catch { /* locked or vanished file */ }
        addNode(dirId, entry.name, KIND.FILE, allocated);
        files++;
        bytes += allocated;
      }
      if ((files & 1023) === 0) report(false);
    }
  }
  report(true);
  return { restricted };
}

/** Sums sizes bottom-up and builds the children index. */
function finalize() {
  for (let id = count - 1; id > 0; id--) {
    size[parent[id]] += size[id];
    fileCount[parent[id]] += fileCount[id];
  }
  buildIndex();
}

function buildIndex() {
  childStart = new Int32Array(count + 1);
  for (let id = 1; id < count; id++) childStart[parent[id] + 1]++;
  for (let i = 1; i <= count; i++) childStart[i] += childStart[i - 1];
  childList = new Int32Array(Math.max(count - 1, 0));
  const fill = childStart.slice(0, count);
  for (let id = 1; id < count; id++) childList[fill[parent[id]]++] = id;
}

/** Adds used-but-unaccounted space as a "Hidden space" node when a whole drive was scanned. */
function addHiddenSpace(used) {
  const hidden = used - size[0];
  if (hidden <= 1024 * 1024) return;
  const id = addNode(0, 'Hidden space', KIND.HIDDEN, hidden);
  size[0] += hidden;
  fileCount[id] = 0;
  buildIndex();
}

// ---- Queries

function children(id) {
  const result = [];
  for (let i = childStart[id]; i < childStart[id + 1]; i++) {
    const child = childList[i];
    if (!deleted[child]) result.push(child);
  }
  return result.sort((a, b) => size[b] - size[a]);
}

function hasChildren(id) {
  for (let i = childStart[id]; i < childStart[id + 1]; i++) if (!deleted[childList[i]]) return true;
  return false;
}

function nodePath(id) {
  const parts = [];
  for (let n = id; n > 0; n = parent[n]) parts.push(names[n]);
  parts.reverse();
  if (!parts.length) return rootPath;
  return (rootPath.endsWith(sep) ? rootPath : rootPath + sep) + parts.join(sep);
}

function ancestors(id) {
  const list = [];
  for (let n = parent[id]; n >= 0; n = parent[n]) list.push(n);
  return list;
}

function describe(id) {
  return { id, name: names[id], size: size[id], kind: kind[id], files: fileCount[id], hasChildren: hasChildren(id) };
}

/** Rings for the map: everything under `id` down to `depth` levels that is big enough to see. */
function rings(id, depth, minSize) {
  return children(id).filter((c) => size[c] >= minSize).map((c) => {
    const node = { id: c, n: names[c], s: size[c], k: kind[c], h: hasChildren(c) ? 1 : 0 };
    if (depth > 1 && node.h) node.c = rings(c, depth - 1, minSize);
    return node;
  });
}

function view({ id, depth, minFraction, listLimit }) {
  if (id < 0 || id >= count || deleted[id]) id = 0;
  const kids = children(id);
  const listCutoff = size[id] * 0.001;
  let visible = kids.filter((c) => size[c] >= listCutoff).slice(0, listLimit);
  if (!visible.length) visible = kids.slice(0, listLimit);
  const rest = kids.slice(visible.length);
  const lineage = ancestors(id).reverse().concat([id]).map((n) => ({ id: n, name: names[n] }));
  return {
    node: describe(id),
    path: nodePath(id),
    lineage,
    rings: rings(id, depth, size[id] * minFraction),
    list: visible.map(describe),
    rest: { count: rest.length, size: rest.reduce((sum, c) => sum + size[c], 0) },
    rootSize: size[0],
    rootFiles: fileCount[0],
  };
}

function find(target) {
  const normalized = path.resolve(target);
  const rootNorm = path.resolve(rootPath);
  const compare = (a, b) => (isWindows ? a.toLowerCase() === b.toLowerCase() : a === b);
  if (compare(normalized, rootNorm)) return 0;
  const prefix = rootNorm.endsWith(sep) ? rootNorm : rootNorm + sep;
  if (!(isWindows ? normalized.toLowerCase().startsWith(prefix.toLowerCase()) : normalized.startsWith(prefix))) return -1;
  let id = 0;
  for (const part of normalized.slice(prefix.length).split(sep).filter(Boolean)) {
    const next = children(id).find((c) => compare(names[c], part));
    if (next === undefined) return -1;
    id = next;
  }
  return id;
}

/** Detaches deleted items and subtracts their size from every ancestor. */
function remove(ids) {
  for (const id of ids) {
    if (id <= 0 || deleted[id]) continue;
    deleted[id] = 1;
    for (let n = parent[id]; n >= 0; n = parent[n]) {
      size[n] -= size[id];
      fileCount[n] -= fileCount[id];
    }
  }
  return { rootSize: size[0], rootFiles: fileCount[0] };
}

function csv(id) {
  const lines = ['Path,Size (bytes),Type'];
  const stack = [id];
  while (stack.length) {
    const n = stack.pop();
    const type = kind[n] === KIND.FILE ? 'File' : kind[n] === KIND.HIDDEN ? 'Other' : 'Folder';
    lines.push('"' + nodePath(n).replace(/"/g, '""') + '",' + size[n] + ',' + type);
    for (const c of children(n).reverse()) stack.push(c);
  }
  return lines.join('\n');
}

// ---- Run

const result = scan();
if (result === false) {
  parentPort.postMessage({ type: 'cancelled' });
} else {
  finalize();
  if (workerData.usedBytes) addHiddenSpace(workerData.usedBytes);
  parentPort.postMessage({ type: 'done', restricted: result.restricted, rootSize: size[0], rootFiles: fileCount[0] });
}

parentPort.on('message', ({ requestId, method, args }) => {
  let value;
  try {
    switch (method) {
      case 'view': value = view(args); break;
      case 'children': value = children(args.id).map(describe); break;
      case 'info': value = args.ids.filter((id) => id >= 0 && id < count && !deleted[id])
        .map((id) => ({ ...describe(id), path: nodePath(id), ancestors: ancestors(id) })); break;
      case 'find': value = args.paths.map(find); break;
      case 'remove': value = remove(args.ids); break;
      case 'csv': value = csv(args.id); break;
      default: throw new Error('Unknown method ' + method);
    }
    parentPort.postMessage({ requestId, value });
  } catch (error) {
    parentPort.postMessage({ requestId, error: String(error && error.message || error) });
  }
});
