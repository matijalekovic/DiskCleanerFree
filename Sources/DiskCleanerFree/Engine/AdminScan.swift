import Foundation
import Synchronization

/// Line-based serialization of a scanned tree, used to hand results from the privileged
/// helper process back to the app. One line per node in pre-order:
/// `<kind><depth>\t<own size>\t<escaped name>\n`
enum TreeCodec {
    private static let kindCodes: [FileNode.Kind: UInt8] = [
        .file: UInt8(ascii: "F"), .folder: UInt8(ascii: "D"), .package: UInt8(ascii: "P"),
        .symlink: UInt8(ascii: "L"), .restricted: UInt8(ascii: "R"), .systemVolume: UInt8(ascii: "S"),
    ]
    private static let kindsByCode: [UInt8: FileNode.Kind] = Dictionary(uniqueKeysWithValues: kindCodes.map { ($1, $0) })

    static func write(_ root: FileNode, to path: String) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? handle.close() }
        var buffer = [UInt8]()
        buffer.reserveCapacity(1 << 20)
        var stack: [(FileNode, Int)] = [(root, 0)]
        while let (node, depth) = stack.popLast() {
            guard let code = kindCodes[node.kind] else { continue }
            let own = node.size - node.children.reduce(0) { $0 + $1.size }
            buffer.append(code)
            buffer.append(contentsOf: "\(depth)\t\(max(own, 0))\t".utf8)
            appendEscaped(node.name, to: &buffer)
            buffer.append(UInt8(ascii: "\n"))
            if buffer.count > (1 << 20) - 4096 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
            for child in node.children.reversed() { stack.append((child, depth + 1)) }
        }
        try handle.write(contentsOf: buffer)
    }

    static func read(from path: String) throws -> FileNode {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        var stack: [FileNode] = []
        var root: FileNode?
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            let n = bytes.count
            while i < n {
                guard let kind = kindsByCode[bytes[i]] else { throw CocoaError(.fileReadCorruptFile) }
                i += 1
                var depth = 0
                while i < n, bytes[i] != 9 { depth = depth * 10 + Int(bytes[i] &- 48); i += 1 }
                i += 1
                var size: Int64 = 0
                while i < n, bytes[i] != 9 { size = size * 10 + Int64(bytes[i] &- 48); i += 1 }
                i += 1
                let start = i
                while i < n, bytes[i] != 10 { i += 1 }
                let name = unescape(UnsafeBufferPointer(rebasing: bytes[start..<i]))
                i += 1

                let node = FileNode(name: name, kind: kind, size: size)
                if kind == .systemVolume { node.basePath = "/" }
                if depth == 0 {
                    root = node
                    stack = [node]
                    continue
                }
                guard depth <= stack.count else { throw CocoaError(.fileReadCorruptFile) }
                stack.removeSubrange(depth...)
                stack[depth - 1].children.append(node)
                stack.append(node)
            }
        }
        guard let root else { throw CocoaError(.fileReadCorruptFile) }
        root.finalizeTree()
        return root
    }

    private static func appendEscaped(_ name: String, to buffer: inout [UInt8]) {
        for byte in name.utf8 {
            switch byte {
            case UInt8(ascii: "\\"): buffer.append(contentsOf: [92, 92])
            case UInt8(ascii: "\n"): buffer.append(contentsOf: [92, UInt8(ascii: "n")])
            default: buffer.append(byte)
            }
        }
    }

    private static func unescape(_ bytes: UnsafeBufferPointer<UInt8>) -> String {
        guard bytes.contains(92) else { return String(decoding: bytes, as: UTF8.self) }
        var out = [UInt8]()
        var escaping = false
        for byte in bytes {
            if escaping {
                out.append(byte == UInt8(ascii: "n") ? 10 : byte)
                escaping = false
            } else if byte == 92 {
                escaping = true
            } else {
                out.append(byte)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Entry point for the copy of the app that runs as root (`--dump`). It scans, then writes the
/// tree to a file and progress counters to a side file the app polls.
enum Dumper {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--dump"), index + 1 < args.count else { return }
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let path = args[index + 1]
        guard let out = value("--out") else { exit(2) }
        let progressPath = value("--progress")
        let progress = ScanProgress()
        let done = Atomic<Bool>(false)

        let reporter = Thread {
            while true {
                if FileManager.default.fileExists(atPath: out + ".cancel") { progress.cancel() }
                if let progressPath {
                    let line = "\(progress.files.load(ordering: .relaxed)) \(progress.bytes.load(ordering: .relaxed)) \(progress.restricted.load(ordering: .relaxed))\n\(progress.currentPath)"
                    try? line.write(toFile: progressPath, atomically: true, encoding: .utf8)
                }
                usleep(200_000)
            }
        }
        reporter.start()

        let root = ScanEngine.scan(path: path, name: value("--name") ?? path,
                                   isStartupDisk: value("--startup") == "1", progress: progress)
        done.store(true, ordering: .relaxed)
        if progress.isCancelled { exit(3) }
        do {
            try TreeCodec.write(root, to: out + ".tmp")
            try FileManager.default.moveItem(atPath: out + ".tmp", toPath: out)
        } catch {
            FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
            exit(1)
        }
        exit(0)
    }
}

/// Runs the scan as root by relaunching this executable through an administrator prompt.
enum AdminScanner {
    enum Failure: LocalizedError {
        case cancelledByUser
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelledByUser: "Administrator access was not granted."
            case .failed(let message): message
            }
        }
    }

    static func scan(path: String, name: String, isStartupDisk: Bool, progress: ScanProgress) throws -> FileNode {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("admin-scan-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let out = dir.appendingPathComponent("tree").path
        let progressFile = dir.appendingPathComponent("progress").path

        guard let executable = Bundle.main.executablePath else { throw Failure.failed("Executable not found.") }
        let command = [executable, "--dump", path, "--name", name, "--startup", isStartupDisk ? "1" : "0",
                       "--out", out, "--progress", progressFile].map(shellQuote).joined(separator: " ")
        let script = "do shell script \"\(appleScriptEscape(command))\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = FileHandle.nullDevice
        try process.run()

        while process.isRunning {
            if progress.isCancelled, !fm.fileExists(atPath: out + ".cancel") {
                fm.createFile(atPath: out + ".cancel", contents: nil)
            }
            if let text = try? String(contentsOfFile: progressFile, encoding: .utf8) {
                let lines = text.split(separator: "\n", maxSplits: 1)
                let numbers = lines.first?.split(separator: " ") ?? []
                if numbers.count == 3 {
                    progress.files.store(Int(numbers[0]) ?? 0, ordering: .relaxed)
                    progress.bytes.store(Int64(numbers[1]) ?? 0, ordering: .relaxed)
                    progress.restricted.store(Int(numbers[2]) ?? 0, ordering: .relaxed)
                }
                if lines.count > 1 { progress.currentPath = String(lines[1]) }
            }
            usleep(150_000)
        }

        if progress.isCancelled { throw CancellationError() }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if message.contains("-128") { throw Failure.cancelledByUser }
            throw Failure.failed(message.isEmpty ? "The administrator scan failed." : message)
        }
        let root = try TreeCodec.read(from: out)
        root.basePath = isStartupDisk ? ScanEngine.dataVolumePath : path
        return root
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
