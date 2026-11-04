import Foundation

/// `DumpShop --dump <bundle-id> [--udid X] [-o out.ipa] [--no-resume]`
/// Runs one dump from the command line using the exact argv the GUI builds.
/// `DumpShop --store-dump <bundle-id> [--label 名称]` is the Route B equivalent.
enum Headless {
    static func run(_ args: [String]) -> Int32 {
        if args.contains("--store-search") { return storeSearch(args) }
        let fromStore = args.contains("--store-dump")
        guard let idx = args.firstIndex(of: fromStore ? "--store-dump" : "--dump"),
              idx + 1 < args.count else { return 2 }
        let bundleId = args[idx + 1]
        var udid = args.firstAfter("--udid") ?? (Runner.sync([Tool.which("idevice_id") ?? "idevice_id", "-l"]).out
            .trimmed.split(separator: "\n").first.map(String.init) ?? "")
        guard !udid.isEmpty else {
            FileHandle.standardError.write(Data("没有可用的设备 UDID\n".utf8))
            return 1
        }
        guard let py = Paths.venvPython.takeIfExecutable() ?? Tool.which("python3") else {
            FileHandle.standardError.write(Data("找不到 python3 环境\n".utf8))
            return 1
        }
        guard let dir = Paths.engineDir(source: ProcessInfo.processInfo.environment["DUMPSHOP_ENGINE"]),
              FileManager.default.fileExists(atPath: dir.appendingPathComponent("dumper.py").path) else {
            FileHandle.standardError.write(Data("找不到 engine 脚本目录\n".utf8))
            return 1
        }
        let noResume = args.contains("--no-resume")
        let outDir = URL(fileURLWithPath: args.firstAfter("-o")
            ?? args.firstAfter("--output-dir")
            ?? Paths.dumps.path, isDirectory: true)
        let work = Paths.scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let app = InstalledApp(bundleId: bundleId, name: args.firstAfter("--label") ?? bundleId)
        let argv: [String]
        if fromStore {
            var item = StoreItem(id: Int(args.firstAfter("--store-id") ?? "") ?? 0,
                                 name: app.name, bundleId: bundleId,
                                 version: args.firstAfter("--version") ?? "?",
                                 seller: "", price: "", artwork: nil, bytes: nil,
                                 genres: [])
            // The device route opens a product page by numeric id, so look it up
            // rather than sending the phone to id0.
            if args.contains("--on-device"), item.id == 0,
               let found = resolveStoreItem(bundleId) {
                item = found
            }
            argv = AppModel.storeDumpArgv(
                py: py, dumper: dir.appendingPathComponent("dumper.py").path, item: item,
                udid: udid, outDir: outDir, work: work,
                // Resolved the same way the GUI does, but without touching the main
                // actor from a synchronous command-line path.
                ipatool: ProcessInfo.processInfo.environment["DUMPSHOP_IPATOOL"]
                    ?? Paths.bundledIpatool?.path ?? Paths.cachedIpatool.takeIfExecutable(),
                cacheRoot: Paths.support.path,
                uninstall: !args.contains("--keep-installed"), noResume: noResume,
                onDevice: args.contains("--on-device"))
        } else {
            argv = AppModel.dumpArgv(py: py,
                                     dumper: dir.appendingPathComponent("dumper.py").path,
                                     app: app, udid: udid, outDir: outDir, work: work,
                                     noResume: noResume)
        }
        FileHandle.standardError.write(Data("运行: \(argv.joined(separator: " "))\n".utf8))
        let sem = DispatchSemaphore(value: 0)
        var code: Int32 = -1
        Runner.stream(argv,
                      onLine: { print($0); fflush(stdout) },
                      onFinish: { c in code = c; sem.signal() })
        sem.wait()
        return code
    }
}

extension [String] {
    func firstAfter(_ flag: String) -> String? {
        guard let i = firstIndex(of: flag), i + 1 < count else { return nil }
        return self[i + 1]
    }
}

extension URL {
    func takeIfExecutable() -> String? {
        FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}

extension Headless {
    /// `DumpShop --store-search <term> [--region CN]` prints what the store panel
    /// would show, which is the only way to exercise the search parser offline.
    static func storeSearch(_ args: [String]) -> Int32 {
        guard let i = args.firstIndex(of: "--store-search"), i + 1 < args.count else { return 2 }
        let term = args[i + 1]
        let region = args.firstAfter("--region") ?? "CN"
        // A CLI has no run loop, and URLSession's completion work is delivered on
        // one, so pump the main run loop until the request settles or times out.
        final class Box: @unchecked Sendable {
            var items: [StoreItem] = []
            var error: String?
            var done = false
        }
        let box = Box()
        DispatchQueue.global(qos: .userInitiated).async {
            let sem = DispatchSemaphore(value: 0)
            Task {
                do { box.items = try await StoreSearch.search(term, region: region, limit: 10) }
                catch { box.error = "\(error)" }
                box.done = true
                sem.signal()
            }
            sem.wait()
        }
        let deadline = Date().addingTimeInterval(45)
        while !box.done && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        if let err = box.error {
            FileHandle.standardError.write(Data("搜索失败: \(err)\n".utf8))
            return 1
        }
        for item in box.items {
            print([item.name, item.bundleId, item.version, item.price,
                   item.sizeText, item.seller].joined(separator: " | "))
        }
        print("count=\(box.items.count) region=\(region)")
        return box.items.isEmpty ? 1 : 0
    }

    /// Resolve a bundle id through the store lookup API, pumping the main run loop
    /// because a command-line process has none of its own.
    static func resolveStoreItem(_ bundleId: String) -> StoreItem? {
        final class Box: @unchecked Sendable {
            var value: StoreItem?
            var done = false
        }
        let box = Box()
        DispatchQueue.global(qos: .userInitiated).async {
            Task {
                box.value = try? await StoreSearch.lookup(bundleId: bundleId)
                box.done = true
            }
        }
        let until = Date().addingTimeInterval(25)
        while !box.done && Date() < until {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        if box.value == nil {
            FileHandle.standardError.write(Data(
                "查不到 \(bundleId) 对应的 trackId，可用 --store-id 手动指定\n".utf8))
        }
        return box.value
    }
}
