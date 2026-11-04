import AppKit
import Foundation

extension AppModel {

    /// Single source of truth for how the engine is invoked, shared by the GUI
    /// and `--dump` so a headless run really exercises the same command line.
    nonisolated static func dumpArgv(py: String, dumper: String, app: InstalledApp, udid: String,
                         outDir: URL, work: URL, noResume: Bool) -> [String] {
        var argv = [py, dumper, "--bundle-id", app.bundleId, "--udid", udid,
                    "-o", outDir.path, "--workdir", work.path, "--python-hint", py,
                    "--app-label", app.name]
        if noResume { argv.append("--no-resume") }
        return argv
    }

    static func safeName(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        let cleaned = s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let out = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return out.isEmpty ? "app" : String(out.prefix(60))
    }

    // MARK: - dump

    func dump(_ app: InstalledApp) {
        guard let dev = selectedDevice, let py = env.py.path, let dir = engineDirURL else {
            notice = env.py.path == nil ? "Python 环境未就绪，请到「环境」页初始化" : "没有选中设备"
            return
        }
        let argv = Self.dumpArgv(py: py, dumper: dir.appendingPathComponent("dumper.py").path,
                                 app: app, udid: dev.udid, outDir: settings.resolvedOutDir,
                                 work: Paths.scratch.appendingPathComponent(UUID().uuidString,
                                                                            isDirectory: true),
                                 noResume: settings.noResume)
        enqueue(argv: argv, app: app, dev: dev, origin: .device)
    }

    /// Queue a whole batch. Anything already pending is skipped, not duplicated.
    func dumpMany(_ apps: [InstalledApp]) {
        guard let dev = selectedDevice, let py = env.py.path, let dir = engineDirURL else {
            notice = "环境或设备未就绪"; return
        }
        var added = 0, skipped = 0
        for app in apps {
            if isBusy(app.bundleId) { skipped += 1; continue }
            let argv = Self.dumpArgv(py: py, dumper: dir.appendingPathComponent("dumper.py").path,
                                     app: app, udid: dev.udid, outDir: settings.resolvedOutDir,
                                     work: Paths.scratch.appendingPathComponent(UUID().uuidString,
                                                                                isDirectory: true),
                                     noResume: settings.noResume)
            if enqueue(argv: argv, app: app, dev: dev, origin: .device) { added += 1 }
        }
        notice = added == 0
            ? "选中的 \(apps.count) 个都已经在队列里了"
            : "已排入 \(added) 个任务" + (skipped > 0 ? "（跳过 \(skipped) 个已在队列）" : "")
    }

    func isBusy(_ bundleId: String) -> Bool {
        jobs.contains { $0.app.bundleId == bundleId
            && ($0.state == .queued || $0.state == .running) }
    }

    /// Put a job in the queue and immediately start it if a slot is free.
    @discardableResult
    func enqueue(argv: [String], app: InstalledApp, dev: IOSDevice, origin: JobOrigin) -> Bool {
        guard dev.injectable else {
            notice = "这台设备还不能注入。先按右侧「环境修复」把通道打通。"
            return false
        }
        guard !isBusy(app.bundleId) else { notice = "\(app.name) 已经在队列里"; return false }
        try? FileManager.default.createDirectory(at: settings.resolvedOutDir,
                                                withIntermediateDirectories: true)
        var job = DumpJob(udid: dev.udid, deviceName: dev.name, app: app)
        job.origin = origin
        job.state = .queued
        job.stage = "排队中"
        jobs.insert(job, at: 0)
        pendingArgv[job.id] = argv
        pumpQueue()
        return true
    }

    /// Launch queued jobs until the parallel limit is reached. Oldest first, so a
    /// batch runs in the order it was picked.
    func pumpQueue() {
        var guardCounter = 0
        while canStartMore, let next = queuedJobs.last, guardCounter < 32 {
            guardCounter += 1
            guard let argv = pendingArgv[next.id] else {
                dropJob(next.id, reason: "缺少启动参数，已跳过")
                continue
            }
            pendingArgv.removeValue(forKey: next.id)
            startJob(next.id, argv: argv)
        }
    }

    private func startJob(_ id: UUID, argv: [String]) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].state = .running
        jobs[idx].stage = "启动"
        notice = "正在砸 \(jobs[idx].app.name)（并行 \(runningCount)/\(max(1, settings.maxParallel))）"
        Runner.stream(argv,
            onLine: { line in
                Task { @MainActor in self.consume(jobID: id, line: line) }
            },
            onFinish: { code in
                Task { @MainActor in self.finish(jobID: id, code: code) }
            })
    }

    func dropJob(_ id: UUID, reason: String) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].state = .failed
        jobs[idx].stage = "已取消"
        jobs[idx].log.append(reason)
        pendingArgv.removeValue(forKey: id)
    }

    /// Only queued jobs can be cancelled; a running one is mid-transfer on the phone.
    func cancelQueued(_ id: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }), jobs[idx].state == .queued
        else { notice = "已经开始的任务不能中断"; return }
        dropJob(id, reason: "已从队列移除")
        notice = "已取消排队中的 \(jobs[idx].app.name)"
        pumpQueue()
    }

    func consume(jobID: UUID, line: String) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard let data = line.data(using: .utf8),
              let ev = try? JSONDecoder().decode(EngineEvent.self, from: data) else {
            jobs[idx].log.append(line); return
        }
        switch ev.e {
        case "stage":
            jobs[idx].stage = Self.stageName(ev.n ?? "")
            jobs[idx].fraction = nil
        case "progress":
            if let d = ev.done, let t = ev.total, t > 0 {
                jobs[idx].fraction = min(max(d / t, 0), 1)
            }
            let f1 = ev.filesDone.map { Int($0) }
            let f2 = ev.filesTotal.map { Int($0) }
            if ev.phase == "pull", let a = f1, let b = f2 {
                jobs[idx].phaseNote = "拉取文件 \(a)/\(b) · \(ev.current ?? "")"
            } else if ev.phase == "dump", let d = ev.done.map({ Int($0) }) {
                let total = ev.total.map { Int($0) } ?? 0
                jobs[idx].phaseNote = "已解密 \(d)/\(total) · \(ev.current ?? "")"
            } else if ev.phase == "download", let d = ev.done {
                jobs[idx].phaseNote = String(format: "App Store 下载中 %.1f MB",
                                             d / 1048576.0)
            } else if ev.phase == "install", let d = ev.done {
                jobs[idx].phaseNote = String(format: "安装到手机 %.0f%%", d)
            } else if ev.phase == "waitinstall", let d = ev.done {
                jobs[idx].phaseNote = "等手机上点「获取」并完成下载 \(Int(d))s"
            }
        case "log":
            let m = ev.m ?? ""
            jobs[idx].log.append(m)
            if jobs[idx].log.count > 600 { jobs[idx].log.removeFirst(jobs[idx].log.count - 600) }
        case "result":
            let url = URL(fileURLWithPath: ev.ipa ?? "")
            jobs[idx].result = DumpResult(
                ipa: url, app: ev.app ?? jobs[idx].app.name,
                bundleId: jobs[idx].app.bundleId, version: ev.version ?? "?",
                binaries: ev.binaries ?? 0, stillEncrypted: ev.stillEncrypted ?? [],
                mb: ev.mb ?? 0, seconds: ev.seconds ?? 0, exe: ev.exe ?? "")
            jobs[idx].stage = "完成"
            jobs[idx].fraction = 1
        case "error":
            jobs[idx].log.append("错误: " + (ev.m ?? ""))
            jobs[idx].stage = "失败"
        default:
            break
        }
    }

    func finish(jobID: UUID, code: Int32) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[idx].finished = Date()
        if jobs[idx].result != nil && code == 0 {
            jobs[idx].state = .succeeded
            notice = "完成: \(jobs[idx].result?.ipa.lastPathComponent ?? "")"
            if let ipa = jobs[idx].result?.ipa {
                jobs[idx].verifyNote = verify(ipa: ipa, of: jobs[idx].app,
                                              exe: jobs[idx].result?.exe ?? "")
                if jobs[idx].verifyNote.hasPrefix("已验证")
                    && settings.autoUninstall && !settings.keepOnDevice
                    && jobs[idx].origin != .store {
                    // A store job removes its own copy inside the engine once the decrypted
                    // package is verified; doing it twice would just fail loudly.
                    uninstallFromPhone(bundleId: jobs[idx].app.bundleId, udid: jobs[idx].udid)
                }
            }
        } else {
            jobs[idx].state = .failed
            notice = "\(jobs[idx].app.name) 砸壳失败，看任务日志找原因"
        }
        // One slot just freed, so the rest of the batch can move up.
        pumpQueue()
        if runningJobs.isEmpty && queuedJobs.isEmpty {
            if let udid = selectedUDID { Task { await loadApps(udid: udid) } }
            sweepIdleDevice()
        }
    }

    /// Once nothing is running, clear any staging file a crashed job may have left.
    private func sweepIdleDevice() {
        guard let dev = selectedDevice, let py = env.py.path, let dir = engineDirURL else { return }
        Task {
            let script = dir.appendingPathComponent("dumper.py").path
            let r = await Runner.run([py, script, "--sweep", "--udid", dev.udid,
                                      "--python-hint", py], timeout: 240)
            if r.ok, let line = r.out.split(separator: "\n").first(where: {
                $0.contains("\"removed\"") }) {
                FileHandle.standardError.write(Data("idle sweep: \(line)\n".utf8))
            }
        }
    }

    static func stageName(_ n: String) -> String {
        ["device": "连接设备", "frida-check": "检查注入通道", "enumerate": "读取应用",
         "spawn": "挂起启动 App", "pull": "拉取 bundle", "dump": "内存解密",
         "verify": "校验产物", "pack": "打包 IPA",
         "store-check": "查询手机是否已装", "store-login": "校验下载会话",
         "store-download": "从 App Store 下载", "store-install": "安装到手机",
         "store-phone": "在手机上打开 App Store",
         "store-cleanup": "卸载手机上的副本"][n] ?? n
    }

    /// Open the finished IPA and confirm the main binary really lost its cryptid.
    func verify(ipa: URL, of app: InstalledApp, exe hint: String = "") -> String {
        guard FileManager.default.fileExists(atPath: ipa.path) else { return "产物不存在" }
        let exe = !hint.isEmpty ? hint : app.executable
        if exe.isEmpty { return "校验跳过：不知道主二进制名，请在产物里自查" }
        let tmp = Paths.scratch.appendingPathComponent("verify-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pattern = "Payload/*.app/" + exe
        let r = Runner.sync(["/usr/bin/unzip", "-o", "-j", ipa.path, pattern, "-d", tmp.path],
                            timeout: 120)
        guard r.ok else { return "校验跳过：没能从 IPA 里取出主二进制" }
        let items = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        guard let first = items.first else { return "校验跳过：IPA 里没有 \(exe)" }
        guard let data = try? Data(contentsOf: tmp.appendingPathComponent(first)),
              let ids = MachO.cryptids(data) else {
            return "校验失败：取出的文件不是可解析的 Mach-O"
        }
        return ids.allSatisfy { $0 == 0 }
            ? "已验证：主二进制 cryptid = 0，壳已脱掉"
            : "警告：主二进制仍带 cryptid，可能只脱了一半"
    }

    // MARK: - remediation

    /// Requirement: drop the App Store copy from the phone once a verified
    /// decrypted IPA is safely on the Mac.
    func uninstallFromPhone(bundleId: String, udid: String) {
        notice = "正在从手机卸载 \(bundleId)…"
        Task {
            var r: Completed
            if let py = env.py.path, let dir = engineDirURL {
                let script = dir.appendingPathComponent("devices.py").path
                r = await Runner.run([py, script, "uninstall", "--udid", udid,
                                      "--bundle-id", bundleId], timeout: 240)
            } else if let exe = Tool.which("ideviceinstaller") {
                r = await Runner.run([exe, "-u", udid, "uninstall", bundleId], timeout: 240)
            } else {
                notice = "没有可用的卸载通道"
                return
            }
            if r.ok {
                notice = "已卸载手机上的 \(bundleId)，脱壳包保留在电脑"
                sizes.removeValue(forKey: bundleId)
                if let udid = selectedUDID { await loadApps(udid: udid) }
            } else {
                notice = "卸载失败: " + String((r.err.trimmed.isEmpty ? r.out : r.err).prefix(160))
            }
        }
    }

    var engineDirURL: URL? { Paths.engineDir(source: settings.engineSource) }

    func mountDDI() {
        guard let dev = selectedDevice, let py = env.py.path, let dir = engineDirURL else {
            notice = "环境未就绪"; return
        }
        busy = true
        actionsLog = ["$ 挂载 iOS \(dev.version) 的 Developer Disk Image（首次会自动下载）"]
        Task {
            let script = dir.appendingPathComponent("mount_ddi.py").path
            let r = await Runner.run([py, script, "--udid", dev.udid], timeout: 600)
            actionsLog.append(contentsOf: r.out.split(separator: "\n").map(String.init))
            busy = false
            notice = r.ok ? "DDI 已挂载，正在重新探测设备" : "挂载失败，见修复日志"
            refresh()
        }
    }

    /// Fetch the frida-server package matching the Mac client, then drop it into
    /// the device Media folder over AFC so Filza/Sileo can install it.
    func prepareFridaServer() {
        guard let dev = selectedDevice else { notice = "没有设备"; return }
        guard let ver = env.clientFridaVersion, !ver.isEmpty else {
            notice = "先初始化 Python 环境"; return
        }
        guard let py = env.py.path else { notice = "Python 环境未就绪"; return }
        busy = true
        actionsLog = ["目标版本 frida \(ver)（必须和 Mac 端一致）"]
        Task {
            let deb = try? await Self.downloadFridaDeb(version: ver)
            if let deb {
                actionsLog.append("已下载 \(deb.lastPathComponent) (\(Int(deb.fileSize ?? 0)/1024/1024)) MB")
                let pmd = URL(fileURLWithPath: py).deletingLastPathComponent()
                    .appendingPathComponent("pymobiledevice3")
                let r = await Runner.run([pmd.path, "afc", "push", deb.path, "/"], timeout: 900)
                actionsLog.append(r.ok ? "已推送到手机 /var/mobile/Media/\(deb.lastPathComponent)"
                                      : "推送失败: " + String((r.err.trimmed.isEmpty ? r.out : r.err).prefix(300)))
            } else {
                actionsLog.append("下载失败：检查网络能否访问 github.com")
            }
            actionsLog.append("手机上：打开 Filza → 私人 → Var/Mobile/Media → 点该 .deb → 右下角“通过 dpkg 安装”")
            actionsLog.append("或在 Sileo 里添加源 https://build.frida.re 直接装 Frida")
            busy = false
            refresh()
        }
    }

    /// Rootless jailbreaks (Dopamine, palera1n rootless) take the arm64 package;
    /// rootful takes arm. Try both so a wrong guess never becomes a dead end.
    private static func downloadFridaDeb(version: String) async throws -> URL {
        let dir = Paths.support.appendingPathComponent("downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for arch in ["iphoneos-arm64", "iphoneos-arm"] {
            let name = "frida_\(version)_\(arch).deb"
            let dst = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dst.path), dst.fileSize ?? 0 > 1_000_000 {
                return dst
            }
            let url = "https://github.com/frida/frida/releases/download/\(version)/\(name)"
            let r = Runner.sync(["/usr/bin/curl", "-fsSL", "--max-time", "900",
                                 "-o", dst.path, url], timeout: 900)
            if r.ok, (dst.fileSize ?? 0) > 1_000_000 { return dst }
        }
        throw NSError(domain: "frida", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "github.com 上找不到 frida \(version) 的 iOS 安装包，检查网络或手动下载"])
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        notice = "已复制到剪贴板"
    }
}

extension URL {
    var fileSize: Int64? {
        (try? resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
    }
}
