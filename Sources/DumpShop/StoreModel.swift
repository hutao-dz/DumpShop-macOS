import Foundation

/// Route B: browse the App Store and turn a store app into a dump job.
///
/// The download session is prepared by the packaged terminal setup script.
/// The app only checks for that persistent session and never renders an
/// account, password, or verification-code form.
extension AppModel {
    var storeScriptURL: URL? { engineDirURL?.appendingPathComponent("store.py") }

    /// Which ipatool to hand the engine: explicit setting, then the bundled copy,
    /// then the one the app already cached for itself.
    func resolvedIpatoolPath(region: String? = nil) -> String? {
        if StoreRegion.code(region ?? storeRegion) != "CN" {
            return Paths.bundledIpatoolProfile?.path
        }
        let s = settings.ipatoolPath.trimmed
        if !s.isEmpty { return s }
        if let bundled = Paths.bundledIpatool { return bundled.path }
        if FileManager.default.isExecutableFile(atPath: Paths.cachedIpatool.path) {
            return Paths.cachedIpatool.path
        }
        return nil
    }

    func storeArgv(_ sub: [String], region: String? = nil) -> [String]? {
        guard let py = env.py.path ?? Paths.fairplayPython(), let script = storeScriptURL,
              let ipatool = resolvedIpatoolPath(region: region) else { return nil }
        let code = region ?? storeRegion
        var argv = [py, script.path, "--cache-root", Paths.support.path,
                    "--profile", code]
        argv += ["--ipatool", ipatool]
        return argv + sub
    }

    // MARK: - catalogue

    func runStoreSearch(_ term: String) async {
        let q = term.trimmed
        let generation = UUID()
        storeSearchGeneration = generation
        let region = storeRegion
        guard !q.isEmpty else { storeResults = []; storeNote = ""; storeBusy = false; return }
        storeBusy = true
        defer { if storeSearchGeneration == generation { storeBusy = false } }
        do {
            let items = try await StoreSearch.search(q, region: region)
            guard !Task.isCancelled, storeSearchGeneration == generation,
                  storeRegion == region else { return }
            storeResults = items
            storeNote = items.isEmpty
                ? "App Store（\(StoreRegion.title(storeRegion))）没有匹配「\(q)」的软件"
                : "\(items.count) 个结果"
            if let sel = selectedStoreID, !items.contains(where: { $0.id == sel }) {
                selectedStoreID = nil
            }
            loadArtwork(items)
        } catch {
            guard !Task.isCancelled, storeSearchGeneration == generation,
                  storeRegion == region else { return }
            storeResults = []
            storeNote = "搜索失败: \(error.localizedDescription)"
        }
    }

    /// Artwork is fetched lazily and never invalidates a row's height, so the list
    /// cannot jump around while images land.
    func loadArtwork(_ items: [StoreItem]) {
        for item in items where storeArt[item.id] == nil {
            guard let url = item.artworkURL200 else { continue }
            let id = item.id
            Task {
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      data.count > 512 else { return }
                self.storeArt[id] = data
            }
        }
    }

    func installedText(_ item: StoreItem) -> String? {
        guard let app = installedMatch(item) else { return nil }
        return "手机已装 \(app.shortVersion)"
    }

    // MARK: - persistent download session

    func refreshStoreAuth(region: String? = nil) {
        let code = StoreRegion.code(region ?? storeRegion)
        let generation = UUID()
        storeAuthGeneration[code] = generation
        guard let argv = storeArgv(["auth-info"], region: code) else {
            // The interpreter probe finishes after launch, so this runs too early on
            // a cold start. Say so instead of wiping a state we already learned.
            var auth = storeAuthByRegion[code] ?? StoreAuth()
            auth.error = "Python 或地区下载组件未就绪，请检查环境"
            storeAuthByRegion[code] = auth
            return
        }
        Task {
            let r = await Runner.run(argv, timeout: 150)
            guard storeAuthGeneration[code] == generation else { return }
            var auth = StoreAuth()
            auth.binary = true
            auth.binarySource = ""
            for line in r.out.split(separator: "\n") {
                parseStoreLine(String(line), into: &auth)
            }
            if !r.ok && auth.error.isEmpty {
                auth.error = r.text.trimmed.isEmpty ? "读取下载会话失败" : r.text
            }
            storeAuthByRegion[code] = auth
        }
    }

    /// Populate one region's session summary without exposing the account secret.
    private func parseStoreLine(_ line: String, into auth: inout StoreAuth) {
        if let d = line.data(using: .utf8),
           let ev = try? JSONDecoder().decode(EngineEvent.self, from: d) {
            switch ev.e {
            case "result":
                var parsed = StoreAuth(ev)
                if parsed.binarySource.isEmpty, let src = ev.source { parsed.binarySource = src }
                auth = parsed
            case "error":
                let m = ev.m ?? "未知错误"
                if !auth.loggedIn { auth.error = m }
            default:
                break
            }
        }
    }

    // MARK: - job

    /// Same argv discipline as `dump`: one builder shared by the GUI and headless,
    /// so a command-line run really exercises the store path.
    nonisolated static func storeDumpArgv(py: String, dumper: String, item: StoreItem,
                                          udid: String, outDir: URL, work: URL,
                                          ipatool: String?, cacheRoot: String,
                                          uninstall: Bool, noResume: Bool,
                                      onDevice: Bool, region: String = "CN",
                                      accountID: String = "") -> [String] {
        var argv = [py, dumper, "--bundle-id", item.bundleId, "--udid", udid,
                    "-o", outDir.path, "--workdir", work.path, "--python-hint", py,
                    "--app-label", item.name, "--from-store",
                    "--cache-root", cacheRoot, "--store-profile", region]
        if !item.isFree { argv.append("--store-no-purchase") }
        if !accountID.isEmpty { argv += ["--store-expected-account", accountID] }
        if onDevice {
            // No credentials involved: the phone downloads it from its own store.
            argv += ["--store-on-device", "--store-url", item.itmsURL]
        } else if let ipatool, !ipatool.isEmpty {
            argv += ["--ipatool", ipatool]
        }
        if uninstall { argv.append("--uninstall-if-installed-by-us") }
        if noResume { argv.append("--no-resume") }
        return argv
    }

    nonisolated static func macOfflineStoreArgv(
        py: String, store: String, item: StoreItem, dest: URL,
        ipatool: String, cacheRoot: String, region: String,
        purchase: Bool = true, accountID: String = "",
        externalVersionID: String = "", expectedVersion: String = ""
    ) -> [String] {
        [py, store, "--cache-root", cacheRoot, "--ipatool", ipatool,
         "--profile", region, "download", "--bundle-id", item.bundleId,
         "--dest", dest.path] + (purchase ? [] : ["--no-purchase"])
            + (accountID.isEmpty ? [] : ["--expected-account", accountID])
            + (externalVersionID.isEmpty ? [] : ["--external-version-id", externalVersionID])
            + (expectedVersion.isEmpty ? [] : ["--expected-version", expectedVersion])
    }

    /// App Store -> Mac only. The personalized IPA is downloaded with the
    /// existing ipatool session and immediately handed to fairplay-decrypt; nothing is
    /// installed on the phone.
    func downloadStoreForMacFairPlay(_ item: StoreItem, version: StoreVersion? = nil) {
        macFairPlay.refresh()
        guard storeAuth.loggedIn else {
            let message = "\(StoreRegion.title(storeRegion))下载会话未初始化。"
                + "先运行随包的“初始化下载会话.command”，选择该地区并登录对应 Apple ID。"
            notice = message
            macFairPlay.showNotice(message)
            return
        }
        guard let credential = macFairPlay.credential(
            region: storeRegion, accountID: storeAuth.accountID) else {
            let message = "请在账号凭据设置中，为\(StoreRegion.title(storeRegion))当前下载账号选择同账号的解密凭据。新增账号需连接越狱 iPhone 提取一次。"
            notice = message
            macFairPlay.showNotice(message)
            presentSettings(.offline)
            return
        }
        guard let py = env.py.path ?? Paths.fairplayPython(), let script = storeScriptURL,
              let ipatool = resolvedIpatoolPath(region: storeRegion) else {
            let message = "Python 或 ipatool 还没准备好"
            notice = message
            macFairPlay.showNotice(message)
            return
        }
        guard macFairPlay.canStartStoreJob else {
            let message = "最多同时处理 \(macFairPlay.maxParallelStoreJobs) 个 App"
            notice = message
            macFairPlay.showNotice(message)
            return
        }
        if let id = macFairPlay.enqueueStoreDownload(
            item: item, py: URL(fileURLWithPath: py),
            storeScript: script, ipatool: ipatool,
            region: storeRegion, purchase: version == nil && item.isFree,
            accountID: storeAuth.accountID, credential: credential, version: version) {
            sidebarSel = .storeJob(id)
        }
    }

    /// Pull the package, install with its receipt, and dump. `onDevice` is kept
    /// only for the command line as a fallback.
    func dumpFromStore(_ item: StoreItem, onDevice: Bool = false) {
        if !onDevice && (!storeAuth.loggedIn || resolvedIpatoolPath(region: storeRegion) == nil) {
            notice = "当前地区的下载会话或下载组件未就绪，请先初始化"
            return
        }
        guard let dev = selectedDevice else { notice = "没有选中设备"; return }
        guard dev.injectable else {
            notice = "这台设备还不能注入。先按右侧「环境修复」把通道打通。"
            return
        }
        guard activeJob == nil else { notice = "已有任务在跑，等它结束"; return }
        guard let py = env.py.path, let dir = engineDirURL else {
            notice = "Python 环境未就绪，请到「环境」页初始化"; return
        }
        try? FileManager.default.createDirectory(at: settings.resolvedOutDir,
                                                withIntermediateDirectories: true)
        let work = Paths.scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let argv = Self.storeDumpArgv(py: py,
                                      dumper: dir.appendingPathComponent("dumper.py").path,
                                      item: item, udid: dev.udid,
                                      outDir: settings.resolvedOutDir, work: work,
                                      ipatool: resolvedIpatoolPath(region: storeRegion),
                                      cacheRoot: Paths.support.path,
                                      uninstall: settings.storeAutoUninstall,
                                      noResume: settings.noResume, onDevice: onDevice,
                                      region: storeRegion, accountID: storeAuth.accountID)
        // Queued like everything else, so a batch of store apps also runs in parallel.
        if enqueue(argv: argv, app: item.asInstalledApp(), dev: dev, origin: .store) {
            notice = onDevice
                ? "已排入队列：\(item.name)（到它时会在手机上打开 App Store）"
                : "已排入队列：\(item.name)（到它时由电脑下载）"
        }
    }

}
