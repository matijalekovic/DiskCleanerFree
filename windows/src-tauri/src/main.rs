// Disk Cleaner Free for Windows (also runs on macOS): Tauri backend.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod cleanup;
mod scanner;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_clipboard_manager::ClipboardExt;
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons, MessageDialogKind};

const BIN: &str = if cfg!(windows) { "Recycle Bin" } else { "Trash" };

struct Session {
    tree: Arc<Mutex<Option<scanner::Tree>>>,
    cancel: Arc<AtomicBool>,
}

#[derive(Default)]
struct AppState {
    sessions: Mutex<HashMap<u32, Session>>,
    next_id: Mutex<u32>,
}

impl AppState {
    fn tree(&self, session: u32) -> Result<Arc<Mutex<Option<scanner::Tree>>>, String> {
        self.sessions.lock().unwrap().get(&session).map(|s| s.tree.clone()).ok_or_else(|| "Scan is no longer available".into())
    }
}

// ---------------------------------------------------------------------------------------- Platform

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PlatformInfo {
    platform: &'static str,
    accent: &'static str,
    bin: &'static str,
    file_manager: &'static str,
}

#[tauri::command]
fn platform_info() -> PlatformInfo {
    PlatformInfo {
        platform: if cfg!(windows) { "win32" } else if cfg!(target_os = "macos") { "darwin" } else { "linux" },
        accent: if cfg!(windows) { "#0067c0" } else { "#0a84ff" },
        bin: BIN,
        file_manager: if cfg!(windows) { "File Explorer" } else if cfg!(target_os = "macos") { "Finder" } else { "Files" },
    }
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Drive {
    path: String,
    name: String,
    is_system: bool,
    removable: bool,
    total: u64,
    free: u64,
    used: u64,
}

fn list_drives() -> Vec<Drive> {
    let disks = sysinfo::Disks::new_with_refreshed_list();
    let mut drives: Vec<Drive> = Vec::new();
    for disk in disks.list() {
        let mount = disk.mount_point().to_string_lossy().into_owned();
        if cfg!(target_os = "macos") && !(mount == "/" || mount.starts_with("/Volumes/")) {
            continue;
        }
        let total = disk.total_space();
        if total == 0 || drives.iter().any(|d| d.path == mount) {
            continue;
        }
        let free = disk.available_space();
        let label = disk.name().to_string_lossy().into_owned();
        let name = if cfg!(windows) {
            let letter = mount.trim_end_matches('\\');
            let fallback = if disk.is_removable() { "USB Drive" } else { "Local Disk" };
            format!("{} ({})", if label.is_empty() { fallback } else { &label }, letter)
        } else if mount == "/" {
            "Macintosh HD".into()
        } else {
            Path::new(&mount).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or(mount.clone())
        };
        let is_system = if cfg!(windows) { mount.to_uppercase().starts_with("C:") } else { mount == "/" };
        drives.push(Drive { path: mount, name, is_system, removable: disk.is_removable(), total, free, used: total.saturating_sub(free) });
    }
    drives.sort_by(|a, b| b.is_system.cmp(&a.is_system).then(a.path.cmp(&b.path)));
    drives
}

#[tauri::command]
fn drives() -> Vec<Drive> {
    list_drives()
}

#[derive(Serialize)]
struct Folder {
    path: String,
    name: String,
    icon: &'static str,
}

#[tauri::command]
fn special_folders(app: AppHandle) -> Vec<Folder> {
    let paths = app.path();
    let mut folders = Vec::new();
    for (dir, icon) in [(paths.home_dir(), "home"), (paths.download_dir(), "download"), (paths.document_dir(), "document")] {
        if let Ok(dir) = dir {
            let name = dir.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            folders.push(Folder { path: dir.to_string_lossy().into_owned(), name, icon });
        }
    }
    folders
}

/// Folders passed on the command line (e.g. dropped onto the app's icon).
#[tauri::command]
fn launch_folders() -> Vec<String> {
    std::env::args().skip(1).filter(|a| !a.starts_with('-') && Path::new(a).is_dir()).collect()
}

#[tauri::command]
async fn choose_folder(app: AppHandle) -> Option<String> {
    app.dialog().file().set_title("Scan Folder").blocking_pick_folder()
        .and_then(|p| p.into_path().ok())
        .map(|p| p.to_string_lossy().into_owned())
}

// ---------------------------------------------------------------------------------------- Scanning

#[tauri::command]
fn scan_start(app: AppHandle, state: State<AppState>, target: String, name: String, is_drive: bool) -> u32 {
    let id = {
        let mut next = state.next_id.lock().unwrap();
        *next += 1;
        *next
    };
    let cancel = Arc::new(AtomicBool::new(false));
    let slot = Arc::new(Mutex::new(None));
    state.sessions.lock().unwrap().insert(id, Session { tree: slot.clone(), cancel: cancel.clone() });
    let capacity = if is_drive { list_drives().into_iter().find(|d| d.path == target) } else { None };

    std::thread::spawn(move || {
        let progress = Arc::new(scanner::Progress::default());
        let finished = Arc::new(AtomicBool::new(false));
        {
            let (app, progress, finished) = (app.clone(), progress.clone(), finished.clone());
            std::thread::spawn(move || {
                while !finished.load(Ordering::Relaxed) {
                    let current = progress.current.lock().unwrap().clone();
                    let _ = app.emit("scan-event", json!({
                        "session": id, "type": "progress",
                        "files": progress.files.load(Ordering::Relaxed), "bytes": progress.bytes.load(Ordering::Relaxed),
                        "restricted": progress.restricted.load(Ordering::Relaxed), "current": current,
                    }));
                    std::thread::sleep(Duration::from_millis(150));
                }
            });
        }
        let result = scanner::scan(Path::new(&target), name, &progress, &cancel);
        finished.store(true, Ordering::Relaxed);
        match result {
            None => {
                let _ = app.emit("scan-event", json!({ "session": id, "type": "cancelled" }));
            }
            Some(mut tree) => {
                if let Some(c) = &capacity {
                    tree.add_hidden_space(c.used);
                }
                let payload = json!({
                    "session": id, "type": "done", "restricted": tree.restricted,
                    "rootSize": tree.root_size(), "rootFiles": tree.root_files(),
                    "capacity": capacity.as_ref().map(|c| json!({ "total": c.total, "free": c.free, "used": c.used })),
                });
                *slot.lock().unwrap() = Some(tree);
                let _ = app.emit("scan-event", payload);
            }
        }
    });
    id
}

#[tauri::command]
fn scan_cancel(state: State<AppState>, session: u32) {
    if let Some(s) = state.sessions.lock().unwrap().get(&session) {
        s.cancel.store(true, Ordering::Relaxed);
    }
}

#[tauri::command]
fn scan_forget(state: State<AppState>, session: u32) {
    if let Some(s) = state.sessions.lock().unwrap().remove(&session) {
        s.cancel.store(true, Ordering::Relaxed);
    }
}

fn ids(value: &Value) -> Vec<u32> {
    value.as_array().map(|a| a.iter().filter_map(|v| v.as_u64()).map(|v| v as u32).collect()).unwrap_or_default()
}

/// Queries about a finished scan.
#[tauri::command]
fn tree(state: State<AppState>, session: u32, method: String, args: Value) -> Result<Value, String> {
    let slot = state.tree(session)?;
    let mut guard = slot.lock().unwrap();
    let tree = guard.as_mut().ok_or("Scan is still running")?;
    Ok(match method.as_str() {
        "view" => tree.view(&args),
        "children" => tree.children_json(args["id"].as_u64().unwrap_or(0) as u32),
        "info" => json!(tree.info(&ids(&args["ids"]))),
        "find" => json!(args["paths"].as_array().map(|a| a.iter().filter_map(|p| p.as_str()).map(|p| tree.find(Path::new(p))).collect::<Vec<_>>()).unwrap_or_default()),
        "remove" => tree.remove(&ids(&args["ids"])),
        other => return Err(format!("Unknown method {other}")),
    })
}

// ---------------------------------------------------------------------------------------- Deleting

#[derive(Deserialize)]
struct TrashItem {
    id: u32,
    path: String,
    name: String,
}

#[tauri::command]
async fn confirm_trash(app: AppHandle, count: u32, size: String) -> bool {
    app.dialog()
        .message(format!("Empty the {BIN} afterwards to actually free the space."))
        .title(format!("Move {count} item{} ({size}) to the {BIN}?", if count == 1 { "" } else { "s" }))
        .kind(MessageDialogKind::Warning)
        .buttons(MessageDialogButtons::OkCancelCustom(format!("Move to {BIN}"), "Cancel".into()))
        .blocking_show()
}

/// Moves items to the Recycle Bin (Trash on macOS), then prunes them from the tree.
#[tauri::command]
async fn trash(state: State<'_, AppState>, session: u32, items: Vec<TrashItem>) -> Result<Value, String> {
    let mut done = Vec::new();
    let mut failed = Vec::new();
    for item in &items {
        match trash::delete(&item.path) {
            Ok(()) => done.push(item.id),
            Err(_) => failed.push(item.name.clone()),
        }
    }
    let totals = match state.tree(session) {
        Ok(slot) if !done.is_empty() => slot.lock().unwrap().as_mut().map(|t| t.remove(&done)),
        _ => None,
    };
    Ok(json!({ "done": done, "failed": failed, "totals": totals }))
}

#[tauri::command]
fn cleanup(state: State<AppState>, session: u32) -> Result<Vec<Value>, String> {
    let slot = state.tree(session)?;
    let guard = slot.lock().unwrap();
    let tree = guard.as_ref().ok_or("Scan is still running")?;
    let mut result = Vec::new();
    for category in cleanup::categories() {
        let mut ids: Vec<u32> = Vec::new();
        for parent in &category.contents_of {
            let id = tree.find(parent);
            if id < 0 {
                continue;
            }
            for child in tree.children_json(id as u32).as_array().into_iter().flatten() {
                let name = child["name"].as_str().unwrap_or_default();
                if child["size"].as_u64().unwrap_or(0) > 0 && !category.exclude_prefix.is_some_and(|p| name.starts_with(p)) {
                    ids.push(child["id"].as_u64().unwrap_or(0) as u32);
                }
            }
        }
        ids.extend(category.paths.iter().map(|p| tree.find(p)).filter(|&id| id > 0).map(|id| id as u32));
        let items: Vec<Value> = tree.info(&ids).into_iter().filter(|i| i["size"].as_u64().unwrap_or(0) > 0).collect();
        if !items.is_empty() {
            result.push(json!({
                "id": category.id, "title": category.title, "detail": category.detail,
                "safety": if category.safe { "safe" } else { "caution" },
                "selectedByDefault": category.selected_by_default, "items": items,
            }));
        }
    }
    Ok(result)
}

#[tauri::command]
async fn export_csv(app: AppHandle, state: State<'_, AppState>, session: u32, id: u32, name: String) -> Result<bool, String> {
    let csv = {
        let slot = state.tree(session)?;
        let guard = slot.lock().unwrap();
        guard.as_ref().map(|t| t.csv(id)).ok_or("Scan is still running")?
    };
    let Some(target) = app.dialog().file().add_filter("CSV", &["csv"]).set_file_name(format!("{name} scan.csv")).blocking_save_file()
    else {
        return Ok(false);
    };
    let path: PathBuf = target.into_path().map_err(|e| e.to_string())?;
    std::fs::write(path, csv).map_err(|e| e.to_string())?;
    Ok(true)
}

// ---------------------------------------------------------------------------------------- Shell

#[tauri::command]
fn reveal(path: String) -> Result<(), String> {
    tauri_plugin_opener::reveal_item_in_dir(path).map_err(|e| e.to_string())
}

#[tauri::command]
fn open_path(path: String) -> Result<(), String> {
    tauri_plugin_opener::open_path(path, None::<&str>).map_err(|e| e.to_string())
}

#[tauri::command]
fn copy_text(app: AppHandle, text: String) -> Result<(), String> {
    app.clipboard().write_text(text).map_err(|e| e.to_string())
}

#[tauri::command]
fn open_privacy_settings() -> Result<(), String> {
    if cfg!(target_os = "macos") {
        tauri_plugin_opener::open_url("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles", None::<&str>)
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .manage(AppState::default())
        .invoke_handler(tauri::generate_handler![
            platform_info, drives, special_folders, launch_folders, choose_folder,
            scan_start, scan_cancel, scan_forget, tree,
            confirm_trash, trash, cleanup, export_csv,
            reveal, open_path, copy_text, open_privacy_settings,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Disk Cleaner Free");
}
