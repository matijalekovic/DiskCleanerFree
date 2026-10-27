// Well-known locations of regenerable files per platform. Only per-user locations: system caches can
// break things and need administrator rights, and app data is never treated as cache.
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

function subdirs(dir, filter = () => true) {
  try {
    return fs.readdirSync(dir, { withFileTypes: true })
      .filter((e) => e.isDirectory() && filter(e.name))
      .map((e) => path.join(dir, e.name));
  } catch {
    return [];
  }
}

/** Chromium browsers keep caches per profile ("Default", "Profile 1", …). */
function chromiumCaches(userData) {
  const profiles = subdirs(userData, (n) => n === 'Default' || n.startsWith('Profile ') || n === 'Guest Profile');
  return profiles.flatMap((p) => ['Cache', 'Code Cache', 'GPUCache', path.join('Service Worker', 'CacheStorage')]
    .map((c) => path.join(p, c)));
}

function windowsCategories() {
  const local = process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local');
  const home = process.env.USERPROFILE || os.homedir();
  const temp = process.env.TEMP || path.join(local, 'Temp');
  return [
    {
      id: 'temp', title: 'Temporary files', safety: 'safe', selectedByDefault: true,
      detail: 'Files apps and installers leave in your Temp folder. Anything still in use is skipped.',
      contentsOf: [temp],
    },
    {
      id: 'browsers', title: 'Browser caches', safety: 'safe', selectedByDefault: true,
      detail: 'Cached web pages and images from Chrome, Edge, Brave and Firefox. Sites load a bit slower the first time afterwards. Close your browsers first.',
      paths: [
        ...chromiumCaches(path.join(local, 'Google', 'Chrome', 'User Data')),
        ...chromiumCaches(path.join(local, 'Microsoft', 'Edge', 'User Data')),
        ...chromiumCaches(path.join(local, 'BraveSoftware', 'Brave-Browser', 'User Data')),
        ...subdirs(path.join(local, 'Mozilla', 'Firefox', 'Profiles')).map((p) => path.join(p, 'cache2')),
      ],
    },
    {
      id: 'windows', title: 'Windows caches', safety: 'safe', selectedByDefault: true,
      detail: 'Internet cache, crash dumps and the graphics shader cache. Windows rebuilds them when needed.',
      paths: [
        path.join(local, 'Microsoft', 'Windows', 'INetCache'),
        path.join(local, 'CrashDumps'),
        path.join(local, 'D3DSCache'),
      ],
    },
    {
      id: 'dev', title: 'Developer caches', safety: 'caution', selectedByDefault: false,
      detail: 'Package caches for npm, Yarn, pip, NuGet, Gradle and Cargo. Your projects aren\'t touched; dependencies are downloaded again the next time you build.',
      paths: [
        path.join(local, 'npm-cache'),
        path.join(local, 'Yarn', 'Cache'),
        path.join(local, 'pip', 'Cache'),
        path.join(local, 'NuGet', 'v3-cache'),
        path.join(home, '.gradle', 'caches'),
        path.join(home, '.cargo', 'registry', 'cache'),
      ],
    },
  ];
}

function macCategories() {
  const home = os.homedir();
  const caches = path.join(home, 'Library', 'Caches');
  return [
    {
      id: 'app', title: 'App caches', safety: 'safe', selectedByDefault: true,
      detail: 'Temporary files apps keep in ~/Library/Caches. Apps rebuild them as needed; quit them first.',
      contentsOf: [caches], exclude: (name) => name.startsWith('com.apple.'),
    },
    {
      id: 'logs', title: 'Logs', safety: 'safe', selectedByDefault: true,
      detail: 'Diagnostic logs in ~/Library/Logs, only useful when troubleshooting.',
      contentsOf: [path.join(home, 'Library', 'Logs')],
    },
    {
      id: 'dev', title: 'Developer caches', safety: 'caution', selectedByDefault: false,
      detail: 'Package and build caches for npm, Bun, Gradle, Cargo and Xcode. Dependencies are downloaded or rebuilt next time.',
      paths: ['.npm/_cacache', '.bun/install/cache', '.gradle/caches', '.cargo/registry/cache',
        'Library/Developer/Xcode/DerivedData'].map((p) => path.join(home, p)),
    },
  ];
}

function categories() {
  return process.platform === 'win32' ? windowsCategories() : macCategories();
}

module.exports = { categories };
