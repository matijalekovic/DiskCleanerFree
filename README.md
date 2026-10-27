# Disk Cleaner Free

A native macOS 26 disk space analyzer written in SwiftUI, with a Liquid Glass interface. It's a clean-room
recreation of the *workflow* of DaisyDisk (scan → interactive sunburst map → collect → delete). No code,
artwork, strings or branding were taken from DaisyDisk.

## Features

- **Disks & folders sidebar**: every mounted volume with a capacity bar, plus starred favorites and recently
  scanned folders. Drop a folder onto the window or the Dock icon to scan it. Mount and unmount events are picked up live.
- **Overview**: a capacity donut (used / purgeable / free), Full Disk Access status and local APFS snapshots.
- **Fast multi-threaded scanner**: the top two directory levels are split into independent `fts` jobs that run on all
  cores. It measures allocated size and counts hard links once. On the Documents folder it was about 2× faster than `du`
  and matched its total to the kilobyte.
- **Startup disk aware**: it scans the data volume, attaches the sealed system volume as its own node so firmlinked folders
  aren't double-counted, and reports **purgeable** and **hidden** space that no file accounts for.
- **Interactive sunburst map**: hover to inspect, click to zoom in, click the center or press Esc to go up, use
  back/forward history (⌘[ / ⌘]) and a breadcrumb path bar. Colors match between the map and the contents list.
- **Contents inspector**: sorted list with size bars and percentages, and "smaller objects" grouping you can expand.
- **Collector**: drag items from the map or list (or from Finder) to the bottom bar, review them, then move them
  to the Trash or delete them immediately (set this in Settings).
- **Scan as Administrator**: relaunches the app's own binary as root through the standard macOS password prompt,
  and streams progress back. It reveals folders owned by the system and other users.
- Quick Look (Space), Show in Finder, Copy Path, Open, CSV export, multiple scans running in parallel, and warnings
  when you quit with a scan running or items collected.

## Windows

`windows/` holds the Windows version, built with [Tauri](https://tauri.app): a Rust backend (multi-threaded
scanner, Recycle Bin, dialogs) with the same interface as the Mac app in plain HTML/CSS/JS (`windows/ui/`). It
uses the Edge WebView2 that ships with Windows 10/11, so the app is only a few MB. Same features: disk map,
contents list with Explorer-style selection, Collector drawer, and Clean Up for temp files and browser and
developer caches. It also runs on macOS, which is handy for development (needs Rust and Node):

```bash
cd windows && npm install && npm run dev
```

GitHub Actions (`.github/workflows/windows.yml`) builds x64 and ARM64 installers plus single-file portable
`.exe`s on Windows whenever a release is published, and attaches them to it. To build on a Windows PC instead:
`npm run build`.

The app isn't code-signed, so Windows SmartScreen may show "Windows protected your PC" on first run:
click **More info › Run anyway**.

## Build (macOS)

Needs only the Xcode Command Line Tools (Swift 6.2, macOS 26 SDK):

```bash
./scripts/build_app.sh
```

This produces `build/Disk Cleaner Free.app` (ad-hoc signed). For development, use `swift build && .build/debug/DiskCleanerFree`.

To make a shareable installer (universal Apple Silicon + Intel, drag-to-Applications disk image):

```bash
./scripts/make_dmg.sh
```

This writes `build/DiskCleanerFree-1.0.dmg` (set `VERSION=1.1` to change the number). The app is ad-hoc signed,
not signed with an Apple Developer ID, so on another Mac Gatekeeper blocks the first launch. The DMG includes a
"How to open" note: System Settings › Privacy & Security › **Open Anyway**, once. Signing with a Developer ID and
notarizing removes that step.

For layout checks, launch arguments open the window at a given size, scan a folder right away, and
optionally put items in the Collector (nothing is deleted):

```bash
open "build/Disk Cleaner Free.app" --args -WindowSize 780x560 -ScanPath /Applications \
  -CollectPaths "/Applications/Claude.app,/Applications/Discord.app"
```

The window adapts as it narrows: below 900 px the sidebar folds away (and returns when there's room), and below
600 px of detail width the contents list hides, so the map always has space.

Note: macOS ties Full Disk Access to the code signature. With ad-hoc signing you may need to re-grant it after
each rebuild (System Settings › Privacy & Security › Full Disk Access).

## Layout

```
Sources/DiskCleanerFree/
  App/       entry point, menu commands, Settings
  Engine/    ScanEngine (parallel fts walker), AdminScan (root helper + tree codec)
  Model/     FileNode tree, ScanSession (scan/navigation/collector), AppModel, volumes
  Views/     sidebar, overview, scanning, report, sunburst, list, collector
scripts/     build_app.sh, make_icon.swift
```
