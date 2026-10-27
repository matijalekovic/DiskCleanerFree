//! Multi-threaded disk scanner and the scanned tree it produces.
//!
//! The top two directory levels are listed up front; every directory below becomes an independent
//! job walked on a worker thread. Each job builds a local subtree that is merged into the global
//! tree afterwards. Nodes are stored in parallel vectors, and a child always has a higher id than
//! its parent, so sizes can be summed in a single reverse pass.

use serde_json::{json, Value};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::Mutex;

pub const FILE: u8 = 0;
pub const DIR: u8 = 1;
pub const LINK: u8 = 2;
pub const RESTRICTED: u8 = 3;
pub const HIDDEN: u8 = 4;

const NO_PARENT: u32 = u32::MAX;
const SPLIT_DEPTH: usize = 2;

/// Live counters shared between the scanning threads and the progress reporter.
#[derive(Default)]
pub struct Progress {
    pub files: AtomicU64,
    pub bytes: AtomicU64,
    pub restricted: AtomicU64,
    pub current: Mutex<String>,
}

#[derive(Default)]
struct Nodes {
    names: Vec<String>,
    parent: Vec<u32>,
    size: Vec<u64>,
    kind: Vec<u8>,
}

impl Nodes {
    fn add(&mut self, parent: u32, name: String, kind: u8, size: u64) -> u32 {
        let id = self.names.len() as u32;
        self.names.push(name);
        self.parent.push(parent);
        self.size.push(size);
        self.kind.push(kind);
        id
    }
}

struct Context<'a> {
    #[cfg_attr(not(unix), allow(dead_code))]
    root_device: Option<u64>,
    excluded: HashSet<PathBuf>,
    seen_inodes: Mutex<HashSet<(u64, u64)>>,
    progress: &'a Progress,
    cancel: &'a AtomicBool,
}

impl Context<'_> {
    fn cancelled(&self) -> bool {
        self.cancel.load(Ordering::Relaxed)
    }

    /// Allocated size of a file, counting each hard-linked inode once.
    fn file_size(&self, meta: &fs::Metadata) -> u64 {
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            let size = meta.blocks() * 512;
            if meta.nlink() > 1 && !self.seen_inodes.lock().unwrap().insert((meta.dev(), meta.ino())) {
                return 0;
            }
            size
        }
        #[cfg(not(unix))]
        {
            let _ = &self.seen_inodes;
            meta.len()
        }
    }

    /// Whether a directory is a mount point of another volume (don't descend).
    fn other_device(&self, _meta: &fs::Metadata) -> bool {
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            if let Some(root) = self.root_device {
                return _meta.dev() != root;
            }
        }
        false
    }

    fn count_file(&self, bytes: u64) {
        self.progress.files.fetch_add(1, Ordering::Relaxed);
        self.progress.bytes.fetch_add(bytes, Ordering::Relaxed);
    }

    fn count_restricted(&self) {
        self.progress.restricted.fetch_add(1, Ordering::Relaxed);
    }
}

/// Paths on the macOS system volume that are other volumes or firmlinks into the data volume.
fn exclusions(root: &Path) -> HashSet<PathBuf> {
    let mut set = HashSet::new();
    if cfg!(target_os = "macos") && root == Path::new("/") {
        for p in ["/System/Volumes", "/Volumes", "/dev", "/private/var/vm"] {
            set.insert(PathBuf::from(p));
        }
        if let Ok(table) = fs::read_to_string("/usr/share/firmlinks") {
            for line in table.lines() {
                if let Some(source) = line.split('\t').next() {
                    if source.starts_with('/') {
                        set.insert(PathBuf::from(source));
                    }
                }
            }
        }
    }
    set
}

fn device_of(_path: &Path) -> Option<u64> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        return fs::metadata(_path).ok().map(|m| m.dev());
    }
    #[allow(unreachable_code)]
    None
}

/// Lists one directory into `nodes`, calling `on_dir` for every subdirectory that should be walked.
fn list_dir(
    ctx: &Context,
    nodes: &mut Nodes,
    id: u32,
    path: &Path,
    mut on_dir: impl FnMut(u32, PathBuf),
) {
    let entries = match fs::read_dir(path) {
        Ok(entries) => entries,
        Err(_) => {
            nodes.kind[id as usize] = RESTRICTED;
            ctx.count_restricted();
            return;
        }
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let Ok(file_type) = entry.file_type() else { continue };
        if file_type.is_symlink() {
            nodes.add(id, name, LINK, 0);
            ctx.count_file(0);
        } else if file_type.is_dir() {
            let child_path = entry.path();
            if ctx.excluded.contains(&child_path) {
                continue;
            }
            let child = nodes.add(id, name, DIR, 0);
            if cfg!(unix) {
                if let Ok(meta) = entry.metadata() {
                    if ctx.other_device(&meta) {
                        continue;
                    }
                }
            }
            on_dir(child, child_path);
        } else {
            let size = entry.metadata().map(|m| ctx.file_size(&m)).unwrap_or(0);
            nodes.add(id, name, FILE, size);
            ctx.count_file(size);
        }
    }
}

/// Lists the top levels on the calling thread and returns the directories to walk in parallel.
fn split(ctx: &Context, nodes: &mut Nodes, id: u32, path: &Path, depth: usize, jobs: &mut Vec<(u32, PathBuf)>) {
    *ctx.progress.current.lock().unwrap() = path.to_string_lossy().into_owned();
    let mut subdirs = Vec::new();
    list_dir(ctx, nodes, id, path, |child, child_path| subdirs.push((child, child_path)));
    for (child, child_path) in subdirs {
        if depth + 1 < SPLIT_DEPTH {
            split(ctx, nodes, child, &child_path, depth + 1, jobs);
        } else {
            jobs.push((child, child_path));
        }
    }
}

/// Walks one subtree depth-first into a local node list whose node 0 is the job's directory.
fn walk(ctx: &Context, path: &Path) -> Nodes {
    let mut nodes = Nodes::default();
    let root = nodes.add(NO_PARENT, String::new(), DIR, 0);
    let mut stack = vec![(root, path.to_path_buf())];
    let mut listed = 0usize;
    while let Some((id, dir)) = stack.pop() {
        if ctx.cancelled() {
            break;
        }
        listed += 1;
        if listed % 256 == 0 {
            *ctx.progress.current.lock().unwrap() = dir.to_string_lossy().into_owned();
        }
        list_dir(ctx, &mut nodes, id, &dir, |child, child_path| stack.push((child, child_path)));
    }
    nodes
}

/// Scans `root`. Returns `None` when cancelled.
pub fn scan(root: &Path, name: String, progress: &Progress, cancel: &AtomicBool) -> Option<Tree> {
    let ctx = Context {
        root_device: device_of(root),
        excluded: exclusions(root),
        seen_inodes: Mutex::new(HashSet::new()),
        progress,
        cancel,
    };
    let mut nodes = Nodes::default();
    let root_id = nodes.add(NO_PARENT, name, DIR, 0);
    let mut jobs = Vec::new();
    split(&ctx, &mut nodes, root_id, root, 0, &mut jobs);

    let next = AtomicUsize::new(0);
    let results: Mutex<Vec<(u32, Nodes)>> = Mutex::new(Vec::with_capacity(jobs.len()));
    let width = std::thread::available_parallelism().map(|n| n.get() * 2).unwrap_or(8).clamp(4, 32).min(jobs.len().max(1));
    std::thread::scope(|scope| {
        for _ in 0..width {
            scope.spawn(|| loop {
                if ctx.cancelled() {
                    break;
                }
                let index = next.fetch_add(1, Ordering::Relaxed);
                let Some((global, path)) = jobs.get(index) else { break };
                let local = walk(&ctx, path);
                results.lock().unwrap().push((*global, local));
            });
        }
    });
    if ctx.cancelled() {
        return None;
    }

    // Merge local subtrees. Parents always precede children, so ids can be remapped in one pass.
    for (global_root, local) in results.into_inner().unwrap() {
        nodes.kind[global_root as usize] = local.kind[0];
        let mut map = vec![0u32; local.names.len()];
        map[0] = global_root;
        for (i, name) in local.names.into_iter().enumerate().skip(1) {
            let parent = map[local.parent[i] as usize];
            map[i] = nodes.add(parent, name, local.kind[i], local.size[i]);
        }
    }
    let restricted = progress.restricted.load(Ordering::Relaxed);
    Some(Tree::build(root.to_path_buf(), nodes, restricted))
}

// ---------------------------------------------------------------------------------------------- Tree

pub struct Tree {
    root_path: PathBuf,
    names: Vec<String>,
    parent: Vec<u32>,
    size: Vec<u64>,
    files: Vec<u64>,
    kind: Vec<u8>,
    deleted: Vec<bool>,
    child_start: Vec<u32>,
    child_list: Vec<u32>,
    pub restricted: u64,
}

impl Tree {
    fn build(root_path: PathBuf, nodes: Nodes, restricted: u64) -> Tree {
        let n = nodes.names.len();
        let mut size = nodes.size;
        let mut files: Vec<u64> = nodes.kind.iter().map(|&k| u64::from(k == FILE || k == LINK)).collect();
        for i in (1..n).rev() {
            let p = nodes.parent[i] as usize;
            size[p] += size[i];
            files[p] += files[i];
        }
        let mut tree = Tree {
            root_path,
            names: nodes.names,
            parent: nodes.parent,
            size,
            files,
            kind: nodes.kind,
            deleted: vec![false; n],
            child_start: Vec::new(),
            child_list: Vec::new(),
            restricted,
        };
        tree.index();
        tree
    }

    fn index(&mut self) {
        let n = self.names.len();
        let mut start = vec![0u32; n + 1];
        for i in 1..n {
            start[self.parent[i] as usize + 1] += 1;
        }
        for i in 1..=n {
            start[i] += start[i - 1];
        }
        let mut fill = start.clone();
        let mut list = vec![0u32; n.saturating_sub(1)];
        for i in 1..n {
            let p = self.parent[i] as usize;
            list[fill[p] as usize] = i as u32;
            fill[p] += 1;
        }
        self.child_start = start;
        self.child_list = list;
    }

    /// Adds used-but-unaccounted space as a "Hidden space" node when a whole drive was scanned.
    pub fn add_hidden_space(&mut self, used: u64) {
        let hidden = used.saturating_sub(self.size[0]);
        if hidden <= 1024 * 1024 {
            return;
        }
        self.names.push("Hidden space".into());
        self.parent.push(0);
        self.size.push(hidden);
        self.files.push(0);
        self.kind.push(HIDDEN);
        self.deleted.push(false);
        self.size[0] += hidden;
        self.index();
    }

    pub fn root_size(&self) -> u64 {
        self.size[0]
    }

    pub fn root_files(&self) -> u64 {
        self.files[0]
    }

    fn valid(&self, id: u32) -> bool {
        (id as usize) < self.names.len() && !self.deleted[id as usize]
    }

    fn children(&self, id: u32) -> Vec<u32> {
        let (a, b) = (self.child_start[id as usize] as usize, self.child_start[id as usize + 1] as usize);
        let mut kids: Vec<u32> = self.child_list[a..b].iter().copied().filter(|&c| !self.deleted[c as usize]).collect();
        kids.sort_unstable_by(|x, y| self.size[*y as usize].cmp(&self.size[*x as usize]));
        kids
    }

    fn has_children(&self, id: u32) -> bool {
        let (a, b) = (self.child_start[id as usize] as usize, self.child_start[id as usize + 1] as usize);
        self.child_list[a..b].iter().any(|&c| !self.deleted[c as usize])
    }

    fn path(&self, id: u32) -> PathBuf {
        let mut parts = Vec::new();
        let mut n = id;
        while n != 0 && n != NO_PARENT {
            parts.push(self.names[n as usize].as_str());
            n = self.parent[n as usize];
        }
        let mut path = self.root_path.clone();
        for part in parts.iter().rev() {
            path.push(part);
        }
        path
    }

    fn ancestors(&self, id: u32) -> Vec<u32> {
        let mut list = Vec::new();
        let mut n = self.parent[id as usize];
        while n != NO_PARENT {
            list.push(n);
            n = self.parent[n as usize];
        }
        list
    }

    fn describe(&self, id: u32) -> Value {
        let i = id as usize;
        json!({ "id": id, "name": self.names[i], "size": self.size[i], "kind": self.kind[i],
                "files": self.files[i], "hasChildren": self.has_children(id) })
    }

    /// Rings for the map: everything under `id` down to `depth` levels that is big enough to see.
    fn rings(&self, id: u32, depth: u32, min_size: f64) -> Value {
        Value::Array(
            self.children(id)
                .into_iter()
                .filter(|&c| self.size[c as usize] as f64 >= min_size)
                .map(|c| {
                    let i = c as usize;
                    let has = self.has_children(c);
                    let mut node = json!({ "id": c, "n": self.names[i], "s": self.size[i], "k": self.kind[i], "h": u8::from(has) });
                    if depth > 1 && has {
                        node["c"] = self.rings(c, depth - 1, min_size);
                    }
                    node
                })
                .collect(),
        )
    }

    pub fn view(&self, args: &Value) -> Value {
        let mut id = args["id"].as_u64().unwrap_or(0) as u32;
        if !self.valid(id) || self.ancestors(id).iter().any(|&a| self.deleted[a as usize]) {
            id = 0;
        }
        let depth = args["depth"].as_u64().unwrap_or(6) as u32;
        let min_fraction = args["minFraction"].as_f64().unwrap_or(0.0005);
        let list_limit = args["listLimit"].as_u64().unwrap_or(120) as usize;
        let size = self.size[id as usize];
        let kids = self.children(id);
        let cutoff = size as f64 * 0.001;
        let mut visible: Vec<u32> = kids.iter().copied().filter(|&c| self.size[c as usize] as f64 >= cutoff).take(list_limit).collect();
        if visible.is_empty() {
            visible = kids.iter().copied().take(list_limit).collect();
        }
        let rest = &kids[visible.len()..];
        let mut lineage: Vec<u32> = self.ancestors(id);
        lineage.reverse();
        lineage.push(id);
        json!({
            "node": self.describe(id),
            "path": self.path(id).to_string_lossy(),
            "lineage": lineage.iter().map(|&n| json!({ "id": n, "name": self.names[n as usize] })).collect::<Vec<_>>(),
            "rings": self.rings(id, depth, size as f64 * min_fraction),
            "list": visible.iter().map(|&c| self.describe(c)).collect::<Vec<_>>(),
            "rest": { "count": rest.len(), "size": rest.iter().map(|&c| self.size[c as usize]).sum::<u64>() },
            "rootSize": self.size[0],
            "rootFiles": self.files[0],
        })
    }

    pub fn children_json(&self, id: u32) -> Value {
        if !self.valid(id) {
            return json!([]);
        }
        Value::Array(self.children(id).into_iter().map(|c| self.describe(c)).collect())
    }

    pub fn info(&self, ids: &[u32]) -> Vec<Value> {
        ids.iter()
            .copied()
            .filter(|&id| self.valid(id))
            .map(|id| {
                let mut v = self.describe(id);
                v["path"] = json!(self.path(id).to_string_lossy());
                v["ancestors"] = json!(self.ancestors(id));
                v
            })
            .collect()
    }

    /// Node for a path on disk, or -1. Case-insensitive on Windows.
    pub fn find(&self, target: &Path) -> i64 {
        let norm = |s: &str| if cfg!(windows) { s.to_lowercase() } else { s.to_string() };
        let root = self.root_path.to_string_lossy();
        let target_str = target.to_string_lossy();
        let (root_n, target_n) = (norm(root.trim_end_matches(['/', '\\'])), norm(target_str.trim_end_matches(['/', '\\'])));
        if root_n == target_n {
            return 0;
        }
        let Some(rest) = target_n.strip_prefix(&root_n) else { return -1 };
        let mut id = 0u32;
        for part in rest.split(['/', '\\']).filter(|p| !p.is_empty()) {
            match self.children(id).into_iter().find(|&c| norm(&self.names[c as usize]) == part) {
                Some(c) => id = c,
                None => return -1,
            }
        }
        i64::from(id)
    }

    /// Detaches deleted items and subtracts their size from every ancestor.
    pub fn remove(&mut self, ids: &[u32]) -> Value {
        for &id in ids {
            if id == 0 || !self.valid(id) {
                continue;
            }
            self.deleted[id as usize] = true;
            let (size, files) = (self.size[id as usize], self.files[id as usize]);
            let mut n = self.parent[id as usize];
            while n != NO_PARENT {
                self.size[n as usize] -= size;
                self.files[n as usize] -= files;
                n = self.parent[n as usize];
            }
        }
        json!({ "rootSize": self.size[0], "rootFiles": self.files[0] })
    }

    pub fn csv(&self, id: u32) -> String {
        let mut out = String::from("Path,Size (bytes),Type\n");
        let mut stack = vec![id];
        while let Some(n) = stack.pop() {
            let kind = match self.kind[n as usize] {
                FILE | LINK => "File",
                HIDDEN => "Other",
                _ => "Folder",
            };
            let path = self.path(n).to_string_lossy().replace('"', "\"\"");
            out.push_str(&format!("\"{}\",{},{}\n", path, self.size[n as usize], kind));
            let mut kids = self.children(n);
            kids.reverse();
            stack.extend(kids);
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scans_and_queries_a_folder() {
        let dir = std::env::temp_dir().join(format!("dcf-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(dir.join("a/b/c")).unwrap();
        fs::write(dir.join("a/b/c/big.bin"), vec![1u8; 300_000]).unwrap();
        fs::write(dir.join("a/small.txt"), b"hello").unwrap();
        fs::write(dir.join("top.txt"), vec![2u8; 50_000]).unwrap();

        let progress = Progress::default();
        let cancel = AtomicBool::new(false);
        let mut tree = scan(&dir, "test".into(), &progress, &cancel).unwrap();
        assert_eq!(tree.root_files(), 3);
        assert!(tree.root_size() >= 350_005);

        let big = tree.find(&dir.join("a/b/c/big.bin"));
        assert!(big > 0);
        let a = tree.find(&dir.join("a")) as u32;
        let before = tree.size[a as usize];
        let view = tree.view(&json!({ "id": a, "depth": 6, "minFraction": 0.0, "listLimit": 120 }));
        assert_eq!(view["lineage"].as_array().unwrap().len(), 2);
        assert_eq!(view["list"][0]["name"], "b");

        tree.remove(&[big as u32]);
        assert!(tree.size[a as usize] < before);
        assert_eq!(tree.find(&dir.join("a/b/c/big.bin")), -1);
        fs::remove_dir_all(&dir).unwrap();
    }
}
