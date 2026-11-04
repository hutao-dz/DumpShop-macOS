import Foundation

/// Which architecture this binary was built for, so the bundle can carry one
/// ipatool per Mac and still pick the right one at run time.
enum Machine {
    static var arch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

/// A .app launched from Finder gets a bare PATH, so helper tools have to be
/// located with the usual Homebrew prefixes added back in.
enum Tool {
    static let prefixes = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
        "/usr/sbin", "/sbin",
        "/Applications/Xcode.app/Contents/Developer/usr/bin",
    ]

    static func env(extra: [String: String] = [:]) -> [String: String] {
        var e = ProcessInfo.processInfo.environment
        var pathDirs = prefixes
        if let bin = Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true) {
            pathDirs.insert(bin.path, at: 0)
        }
        e["PATH"] = pathDirs.joined(separator: ":")
        e["LC_ALL"] = "en_US.UTF-8"
        // The engine scripts live inside the .app, and a stray __pycache__ there
        // would break the bundle's code signature.
        e["PYTHONDONTWRITEBYTECODE"] = "1"
        for (k, v) in extra { e[k] = v }
        return e
    }

    static func which(_ name: String) -> String? {
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin/" + name),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }
        for dir in prefixes {
            let p = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func missingRequired() -> [String] {
        ["idevice_id", "ideviceinstaller", "zip"].filter { which($0) == nil }
    }
}

struct Completed {
    var code: Int32
    var out: String
    var err: String
    var ok: Bool { code == 0 }
    var text: String { out.trimmed.isEmpty ? err : out }
}

enum Runner {
    static func run(_ argv: [String], environment: [String: String] = [:],
                    timeout: TimeInterval = 60) async -> Completed {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: argv[0])
                proc.arguments = Array(argv.dropFirst())
                proc.environment = Tool.env(extra: environment)
                let o = Pipe(), e = Pipe()
                proc.standardOutput = o
                proc.standardError = e
                do {
                    try proc.run()
                } catch {
                    cont.resume(returning: Completed(code: -1, out: "", err: "\(error)"))
                    return
                }
                // SIGTERM alone is not enough: a python child parked inside a
                // blocking frida call ignores it, which used to wedge refresh().
                let t = DispatchSource.makeTimerSource(queue: .global())
                t.schedule(deadline: .now() + timeout)
                t.setEventHandler {
                    guard proc.isRunning else { return }
                    proc.terminate()
                    let pid = proc.processIdentifier
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if proc.isRunning { kill(pid, SIGKILL) }
                    }
                }
                t.resume()
                let od = o.fileHandleForReading.readDataToEndOfFile()
                let ed = e.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                t.cancel()
                cont.resume(returning: Completed(
                    code: proc.terminationStatus,
                    out: String(data: od, encoding: .utf8) ?? "",
                    err: String(data: ed, encoding: .utf8) ?? ""))
            }
        }
    }

    /// Short binary-producing command, used to read an IPA's Info.plist without
    /// extracting the whole package to disk.
    static func data(_ argv: [String], timeout: TimeInterval = 60) async -> Data? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: argv[0])
                proc.arguments = Array(argv.dropFirst())
                proc.environment = Tool.env()
                let o = Pipe(), e = Pipe()
                proc.standardOutput = o
                proc.standardError = e
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler {
                    guard proc.isRunning else { return }
                    proc.terminate()
                    let pid = proc.processIdentifier
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if proc.isRunning { kill(pid, SIGKILL) }
                    }
                }
                timer.resume()
                do {
                    try proc.run()
                } catch {
                    timer.cancel()
                    cont.resume(returning: nil)
                    return
                }
                let data = o.fileHandleForReading.readDataToEndOfFile()
                _ = e.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                timer.cancel()
                cont.resume(returning: proc.terminationStatus == 0 ? data : nil)
            }
        }
    }

    /// Long-running command; stdout arrives line by line on a background queue.
    static func stream(_ argv: [String],
                       environment: [String: String] = [:],
                       onLine: @escaping @Sendable (String) -> Void,
                       onFinish: @escaping @Sendable (Int32) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: argv[0])
            proc.arguments = Array(argv.dropFirst())
            proc.environment = Tool.env(extra: environment)
            let o = Pipe(), e = Pipe()
            proc.standardOutput = o
            proc.standardError = e
            proc.terminationHandler = { p in onFinish(p.terminationStatus) }
            DispatchQueue(label: "dump.stdout").async {
                let h = o.fileHandleForReading
                var pending = ""
                while true {
                    let d = h.availableData
                    if d.isEmpty { break }
                    if let s = String(data: d, encoding: .utf8) {
                        pending += s
                        while let newline = pending.firstIndex(of: "\n") {
                            let line = String(pending[..<newline])
                            pending = String(pending[pending.index(after: newline)...])
                            if !line.isEmpty { onLine(line) }
                        }
                    }
                }
                if !pending.isEmpty { onLine(pending) }
            }
            DispatchQueue.global().async {
                let d = e.fileHandleForReading.readDataToEndOfFile()
                if let s = String(data: d, encoding: .utf8), !s.trimmed.isEmpty {
                    onLine("[stderr] " + s.trimmed)
                }
            }
            do { try proc.run() } catch { onFinish(-1) }
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension Runner {
    /// Synchronous variant for short calls that must not interleave with a job.
    static func sync(_ argv: [String], environment: [String: String] = [:],
                     timeout: TimeInterval = 60) -> Completed {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: argv[0])
        proc.arguments = Array(argv.dropFirst())
        proc.environment = Tool.env(extra: environment)
        let o = Pipe(), e = Pipe()
        proc.standardOutput = o
        proc.standardError = e
        do { try proc.run() } catch { return Completed(code: -1, out: "", err: "\(error)") }
        let od = o.fileHandleForReading.readDataToEndOfFile()
        let ed = e.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return Completed(code: proc.terminationStatus,
                         out: String(data: od, encoding: .utf8) ?? "",
                         err: String(data: ed, encoding: .utf8) ?? "")
    }

    /// Stream stdout lines while handing the caller a live stdin writer.
    ///
    /// The Apple ID sign-in needs this shape: the password goes down the pipe
    /// immediately (never in argv, where any same-user process could read it), the
    /// pipe stays open, and a 2FA code can be written later, while the sign-in is
    /// already in flight.
    static func stream(_ argv: [String], stdin openStdin: @escaping @Sendable (StreamWriter) -> Void,
                       onLine: @escaping @Sendable (String) -> Void,
                       onFinish: @escaping @Sendable (Int32) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: argv[0])
            proc.arguments = Array(argv.dropFirst())
            proc.environment = Tool.env()
            let i = Pipe(), o = Pipe(), e = Pipe()
            proc.standardInput = i
            proc.standardOutput = o
            proc.standardError = e
            proc.terminationHandler = { p in onFinish(p.terminationStatus) }
            DispatchQueue(label: "store.stdout").async {
                let h = o.fileHandleForReading
                while true {
                    let d = h.availableData
                    if d.isEmpty { break }
                    if let s = String(data: d, encoding: .utf8) {
                        for line in s.split(separator: "\n") { onLine(String(line)) }
                    }
                }
            }
            DispatchQueue.global().async {
                let d = e.fileHandleForReading.readDataToEndOfFile()
                if let s = String(data: d, encoding: .utf8), !s.trimmed.isEmpty {
                    onLine("[stderr] " + s.trimmed)
                }
            }
            do {
                try proc.run()
                openStdin(StreamWriter(i.fileHandleForWriting))
            } catch {
                onFinish(-1)
            }
        }
    }
}

/// A stdin pipe that outlives the call which created it.
final class StreamWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var closed = false

    init(_ handle: FileHandle) { self.handle = handle }

    func writeLine(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !text.isEmpty else { return }
        handle.write(Data((text + "\n").utf8))
    }

    /// Closing signals end-of-input, which is how a cancelled sign-in is aborted.
    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? handle.close()
    }
}
