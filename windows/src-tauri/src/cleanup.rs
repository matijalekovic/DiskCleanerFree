//! Well-known locations of regenerable files. Only per-user locations: system caches can break things
//! and need administrator rights, and app data is never treated as cache.

use std::fs;
use std::path::{Path, PathBuf};

pub struct Category {
    pub id: &'static str,
    pub title: &'static str,
    pub detail: &'static str,
    pub safe: bool,
    pub selected_by_default: bool,
    /// Every item inside these folders is a candidate.
    pub contents_of: Vec<PathBuf>,
    /// These folders themselves are candidates.
    pub paths: Vec<PathBuf>,
    /// Skip items whose name starts with this prefix (e.g. Apple's own caches).
    pub exclude_prefix: Option<&'static str>,
}

fn subdirs(dir: &Path, keep: impl Fn(&str) -> bool) -> Vec<PathBuf> {
    fs::read_dir(dir)
        .map(|entries| {
            entries
                .flatten()
                .filter(|e| e.file_type().map(|t| t.is_dir()).unwrap_or(false))
                .filter(|e| keep(&e.file_name().to_string_lossy()))
                .map(|e| e.path())
                .collect()
        })
        .unwrap_or_default()
}

fn env_path(name: &str) -> Option<PathBuf> {
    std::env::var_os(name).map(PathBuf::from)
}

fn home() -> PathBuf {
    env_path("USERPROFILE").or_else(|| env_path("HOME")).unwrap_or_default()
}

/// Chromium browsers keep caches per profile ("Default", "Profile 1", …).
fn chromium_caches(user_data: PathBuf) -> Vec<PathBuf> {
    subdirs(&user_data, |n| n == "Default" || n.starts_with("Profile ") || n == "Guest Profile")
        .into_iter()
        .flat_map(|p| {
            ["Cache", "Code Cache", "GPUCache"]
                .iter()
                .map(|c| p.join(c))
                .chain(std::iter::once(p.join("Service Worker").join("CacheStorage")))
                .collect::<Vec<_>>()
        })
        .collect()
}

#[cfg(windows)]
pub fn categories() -> Vec<Category> {
    let home = home();
    let local = env_path("LOCALAPPDATA").unwrap_or_else(|| home.join("AppData").join("Local"));
    let temp = env_path("TEMP").unwrap_or_else(|| local.join("Temp"));
    let mut browsers = Vec::new();
    browsers.extend(chromium_caches(local.join("Google").join("Chrome").join("User Data")));
    browsers.extend(chromium_caches(local.join("Microsoft").join("Edge").join("User Data")));
    browsers.extend(chromium_caches(local.join("BraveSoftware").join("Brave-Browser").join("User Data")));
    browsers.extend(subdirs(&local.join("Mozilla").join("Firefox").join("Profiles"), |_| true).into_iter().map(|p| p.join("cache2")));
    vec![
        Category {
            id: "temp", title: "Temporary files", safe: true, selected_by_default: true,
            detail: "Files apps and installers leave in your Temp folder. Anything still in use is skipped.",
            contents_of: vec![temp], paths: vec![], exclude_prefix: None,
        },
        Category {
            id: "browsers", title: "Browser caches", safe: true, selected_by_default: true,
            detail: "Cached web pages and images from Chrome, Edge, Brave and Firefox. Sites load a bit slower the first time afterwards. Close your browsers first.",
            contents_of: vec![], paths: browsers, exclude_prefix: None,
        },
        Category {
            id: "windows", title: "Windows caches", safe: true, selected_by_default: true,
            detail: "Internet cache, crash dumps and the graphics shader cache. Windows rebuilds them when needed.",
            contents_of: vec![],
            paths: vec![local.join("Microsoft").join("Windows").join("INetCache"), local.join("CrashDumps"), local.join("D3DSCache")],
            exclude_prefix: None,
        },
        Category {
            id: "dev", title: "Developer caches", safe: false, selected_by_default: false,
            detail: "Package caches for npm, Yarn, pip, NuGet, Gradle and Cargo. Your projects aren't touched; dependencies are downloaded again the next time you build.",
            contents_of: vec![],
            paths: vec![
                local.join("npm-cache"), local.join("Yarn").join("Cache"), local.join("pip").join("Cache"),
                local.join("NuGet").join("v3-cache"), home.join(".gradle").join("caches"), home.join(".cargo").join("registry").join("cache"),
            ],
            exclude_prefix: None,
        },
    ]
}

#[cfg(not(windows))]
pub fn categories() -> Vec<Category> {
    let home = home();
    let _ = chromium_caches;
    vec![
        Category {
            id: "app", title: "App caches", safe: true, selected_by_default: true,
            detail: "Temporary files apps keep in ~/Library/Caches. Apps rebuild them as needed; quit them first.",
            contents_of: vec![home.join("Library/Caches")], paths: vec![], exclude_prefix: Some("com.apple."),
        },
        Category {
            id: "logs", title: "Logs", safe: true, selected_by_default: true,
            detail: "Diagnostic logs in ~/Library/Logs, only useful when troubleshooting.",
            contents_of: vec![home.join("Library/Logs")], paths: vec![], exclude_prefix: None,
        },
        Category {
            id: "dev", title: "Developer caches", safe: false, selected_by_default: false,
            detail: "Package and build caches for npm, Bun, Gradle, Cargo and Xcode. Dependencies are downloaded or rebuilt next time.",
            contents_of: vec![],
            paths: [".npm/_cacache", ".bun/install/cache", ".gradle/caches", ".cargo/registry/cache", "Library/Developer/Xcode/DerivedData"]
                .iter().map(|p| home.join(p)).collect(),
            exclude_prefix: None,
        },
    ]
}
