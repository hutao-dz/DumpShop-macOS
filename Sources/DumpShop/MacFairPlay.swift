import AppKit
import Foundation
import UniformTypeIdentifiers

struct FairPlayCredentialFile: Identifiable, Hashable {
    let url: URL
    let modified: Date
    let label: String
    let deviceName: String

    var id: String { url.path }
    var path: String { url.path }
    var title: String {
        let stamp = modified.formatted(date: .abbreviated, time: .shortened)
        let suffix = deviceName.isEmpty ? "" : " · \(deviceName)"
        return "\(label)\(suffix) · \(stamp)"
    }
}

struct FairPlayDevice: Identifiable, Hashable {
    let udid: String
    let name: String
    let version: String

    var id: String { udid }
    var title: String {
        version.isEmpty ? name : "\(name) · iOS \(version)"
    }
}

struct IPAIdentity {
    let name: String
    let version: String
    let bundleId: String

    static func read(_ ipa: URL) async -> IPAIdentity {
        let fallback = ipa.deletingPathExtension().lastPathComponent
        let unzip = Tool.which("unzip") ?? "/usr/bin/unzip"
        let listing = await Runner.run([unzip, "-Z1", ipa.path], timeout: 120)
        let infoPath = listing.out.split(separator: "\n")
            .map(String.init)
            .filter {
                let parts = $0.split(separator: "/")
                return parts.count == 3 && parts[0] == "Payload"
                    && parts[1].hasSuffix(".app") && parts[2] == "Info.plist"
            }
            .sorted { $0.count < $1.count }
            .first
        guard let infoPath,
              let data = await Runner.data([unzip, "-p", ipa.path, infoPath], timeout: 120),
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any] else {
            return IPAIdentity(name: fallback, version: "未知版本", bundleId: "")
        }
        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String) ?? fallback
        let version = (plist["CFBundleShortVersionString"] as? String)
            ?? (plist["CFBundleVersion"] as? String) ?? "未知版本"
        return IPAIdentity(name: name, version: version,
                           bundleId: (plist["CFBundleIdentifier"] as? String) ?? "")
    }
}

enum MacStoreJobState: String {
    case downloading = "下载中"
    case decrypting = "解密中"
    case verifying = "校验中"
    case completed = "完成"
    case failed = "失败"

    var isActive: Bool {
        self == .downloading || self == .decrypting || self == .verifying
    }
}

struct MacStoreJob: Identifiable {
    let id = UUID()
    let item: StoreItem
    let region: String
    let purchase: Bool
    let accountID: String
    let workDirectory: URL
    let credentialURL: URL
    let credentialTitle: String
    var requestedVersion: StoreVersion? = nil
    var state: MacStoreJobState = .downloading
    var stage = "准备下载"
    var progressFraction: Double?
    var progressDetail = ""
    var progressDone: Int64 = 0
    var progressTotal: Int64?
    var log: [String] = []
    var downloadedIPA: URL?
    var outputURL: URL?
    var verified: Bool?
    var encryptedImages = 0
    var decryptedPages = 0
    var finished: Date?
    var failureMessage = ""

    mutating func initialise(total: Int64?) {
        progressTotal = total
        progressFraction = total == nil ? nil : 0
        progressDetail = "正在向 App Store 请求下载"
        stage = "正在下载 0%"
    }
}

@MainActor
final class MacFairPlayController: ObservableObject {
    @Published var helperURL: URL? = Paths.fairplayHelper()
    @Published var credentials: [FairPlayCredentialFile] = []
    @Published var selectedCredentialPath = ""
    @Published var devices: [FairPlayDevice] = []
    @Published var selectedDeviceUDID = ""
    @Published var sshPort = "2222"
    @Published var sshLoginMode = "root"
    @Published var sshPassword = ""
    @Published var credentialLabel = "主账号"
    @Published var setupIPA: URL?
    @Published var inputIPA: URL?
    @Published var inputIdentity: IPAIdentity?
    @Published private(set) var busy = false
    @Published var stage = "检查 fairplay-decrypt 环境"
    @Published var log: [String] = []
    @Published var lastOutput: URL?
    @Published var plaintextVerified: Bool?
    @Published var encryptedImages = 0
    @Published var decryptedPages = 0
    @Published var progressFraction: Double?
    @Published var progressDetail = ""
    @Published var progressDone: Int64 = 0
    @Published var progressTotal: Int64?
    @Published var storeJobs: [MacStoreJob] = []
    @Published private(set) var credentialBindings: [String: String] =
        UserDefaults.standard.dictionary(forKey: "fairplay.credentialBindings") as? [String: String] ?? [:]

    private var removeTemporaryInput = false
    private var deviceTask: Task<Void, Never>?
    private var exclusiveBusy = false

    @Published private(set) var maxParallelStoreJobs = AppSettings.shared.maxMacParallel

    func setStoreParallelLimit(_ count: Int) {
        guard count > 0 else { return }
        maxParallelStoreJobs = count
        AppSettings.shared.maxMacParallel = count
        AppSettings.shared.save()
    }

    init() {
        sshPort = UserDefaults.standard.string(forKey: "fairplay.sshPort") ?? "2222"
        sshLoginMode = UserDefaults.standard.string(forKey: "fairplay.sshLoginMode")
            ?? "root"
        refresh()
    }

    var selectedCredential: FairPlayCredentialFile? {
        credentials.first { $0.path == selectedCredentialPath } ?? credentials.first
    }

    var credentialReady: Bool { selectedCredential != nil }
    nonisolated static func credentialBindingKey(region: String, accountID: String) -> String {
        "\(StoreRegion.code(region))|\(accountID)"
    }

    func credential(region: String, accountID: String) -> FairPlayCredentialFile? {
        guard !accountID.isEmpty,
              let path = credentialBindings[Self.credentialBindingKey(
                region: region, accountID: accountID)] else { return nil }
        return credentials.first { $0.path == path }
    }

    func bindCredential(path: String, region: String, accountID: String) {
        guard !accountID.isEmpty else { return }
        let key = Self.credentialBindingKey(region: region, accountID: accountID)
        if credentials.contains(where: { $0.path == path }) {
            credentialBindings[key] = path
        } else {
            credentialBindings.removeValue(forKey: key)
        }
        UserDefaults.standard.set(credentialBindings, forKey: "fairplay.credentialBindings")
    }
    var modelReady: Bool { credentialReady }
    var selectedDevice: FairPlayDevice? {
        devices.first { $0.udid == selectedDeviceUDID } ?? devices.first
    }

    var outputDirectory: URL { AppSettings.shared.resolvedOutDir }
    var activeStoreJobs: [MacStoreJob] {
        storeJobs.filter { $0.state.isActive }
    }
    var activeStoreCount: Int { activeStoreJobs.count }
    var canStartStoreJob: Bool { activeStoreCount < maxParallelStoreJobs }

    func activeStoreJob(bundleId: String, region: String, accountID: String) -> MacStoreJob? {
        storeJobs.first {
            $0.item.bundleId == bundleId && $0.region == region
                && $0.accountID == accountID && $0.state.isActive
        }
    }

    func refresh() {
        helperURL = Paths.fairplayHelper()
        createPrivateDirectories()
        scanCredentials()
        refreshDevices()
        updateStage()
    }

    func refreshDevices() {
        deviceTask?.cancel()
        deviceTask = Task { await scanDevices() }
    }

    private func scanDevices() async {
        guard let ideviceID = Tool.which("idevice_id") else {
            devices = []
            selectedDeviceUDID = ""
            updateStage()
            return
        }
        let listing = await Runner.run([ideviceID, "-l"], timeout: 10)
        guard !Task.isCancelled else { return }
        let udids = listing.out.split(separator: "\n")
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var found: [FairPlayDevice] = []
        for udid in udids {
            let name = await deviceValue("DeviceName", udid: udid)
            let version = await deviceValue("ProductVersion", udid: udid)
            found.append(FairPlayDevice(
                udid: udid,
                name: name.isEmpty ? "iPhone" : name,
                version: version))
        }
        guard !Task.isCancelled else { return }
        devices = found
        if !found.contains(where: { $0.udid == selectedDeviceUDID }) {
            selectedDeviceUDID = found.first?.udid ?? ""
        }
        updateStage()
    }

    private func deviceValue(_ key: String, udid: String) async -> String {
        guard let ideviceInfo = Tool.which("ideviceinfo") else { return "" }
        let result = await Runner.run(
            [ideviceInfo, "-u", udid, "-k", key], timeout: 12)
        return result.ok ? result.out.trimmed : ""
    }

    func chooseSetupIPA() {
        chooseIPA { self.setupIPA = $0 }
    }

    func chooseInputIPA() {
        chooseIPA { url in
            inputIPA = url
            inputIdentity = nil
            Task {
                let info = await IPAIdentity.read(url)
                guard self.inputIPA == url else { return }
                inputIdentity = info
            }
        }
    }

    func repairLicense(region: String, accountID: String) -> URL? {
        guard !accountID.isEmpty else { return nil }
        let url = repairLicenseDestination(region: region, accountID: accountID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func repairLicenseDestination(region: String, accountID: String) -> URL {
        Paths.support.appendingPathComponent("fairplay-repair", isDirectory: true)
            .appendingPathComponent("\(StoreRegion.code(region))-\(Self.filePart(accountID)).sinf")
    }

    func extractCredential(region: String, accountID: String) {
        guard !busy else { return }
        // A previous account's first installed app must not be silently reused
        // when adding another regional account.
        if setupIPA == nil || setupIPA?.pathExtension == "sinf" {
            setupIPA = repairLicense(region: region, accountID: accountID)
        }
        guard credentials.isEmpty || setupIPA != nil else {
            notice("添加账号需要对应账号的授权定位。请先下载该地区的一个 App，或选择该账号下载的 IPA，再重新提取。")
            return
        }
        guard let runtime = fairplayRuntime() else {
            notice("找不到 fairplay-decrypt 运行环境"); return
        }
        let udid = selectedDevice?.udid ?? selectedDeviceUDID
        guard !udid.isEmpty else {
            notice("没有检测到已连接且已信任的越狱 iPhone"); return
        }
        guard let port = Int(sshPort.trimmed), (1...65535).contains(port) else {
            notice("USB SSH 端口必须在 1 到 65535 之间"); return
        }
        let dopamineSudo = sshLoginMode == "dopamine"
        guard !dopamineSudo || !sshPassword.isEmpty else {
            notice("Dopamine 模式需要先设置并输入 mobile 密码"); return
        }
        guard let bundle = Paths.fairplayDeviceBundle() else {
            notice("应用内缺少设备端 fairplay-decrypt 组件"); return
        }
        try? FileManager.default.createDirectory(
            at: Paths.fairplayStaging, withIntermediateDirectories: true)
        let output = Paths.fairplayStaging.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        var argv = runtime.prefix + [
            "retrieve", "--bundle", bundle.path,
            "--output-dir", output.path,
            "--device-udid", udid,
            "--ssh-port", String(port),
        ]
        if let setupIPA {
            argv += [setupIPA.pathExtension == "sinf" ? "--sinf" : "--ipa", setupIPA.path]
        }
        var environment = runtime.environment
        if !sshPassword.isEmpty {
            environment["FAIRPLAY_SSH_PASSWORD"] = sshPassword
        }
        if dopamineSudo {
            environment["FAIRPLAY_SSH_USER"] = "mobile"
            environment["FAIRPLAY_SSH_USE_SUDO"] = "1"
        }
        setExclusiveBusy(true)
        plaintextVerified = nil
        log = [
            "开始为 \(selectedDevice?.name ?? "iPhone") 提取账号凭据。",
            setupIPA == nil
                ? "未选择 IPA：使用手机里第一个可用的 App Store 授权。"
                : "使用下载账号的授权定位同一个 Apple 账号。",
            sshPassword.isEmpty
                ? "SSH 认证：使用现有密钥。"
                : "SSH 认证：使用本次输入的密码，不写入日志。",
            dopamineSudo
                ? "登录账户：mobile，通过 Dopamine sudo 提权。"
                : "登录账户：root。",
        ]
        stage = "连接 USB SSH 并启动设备端提取器"
        UserDefaults.standard.set(sshPort, forKey: "fairplay.sshPort")
        UserDefaults.standard.set(sshLoginMode, forKey: "fairplay.sshLoginMode")
        Runner.stream(
            argv,
            environment: environment,
            onLine: { line in
                Task { @MainActor in self.append(line) }
            },
            onFinish: { code in
                Task { @MainActor in self.finishExtraction(code: code, output: output) }
            })
    }

    func decryptSelectedIPA() {
        guard !busy else { return }
        guard let ipa = inputIPA,
              FileManager.default.fileExists(atPath: ipa.path) else {
            notice("请先选择一个已有的加密 IPA"); return
        }
        beginDecrypt(ipa, removeAfterSuccess: false)
    }

    func showNotice(_ text: String) {
        notice(text)
    }

    @discardableResult
    func enqueueStoreDownload(
        item: StoreItem, py: URL, storeScript: URL, ipatool: String,
        region: String, purchase: Bool, accountID: String,
        credential: FairPlayCredentialFile, version: StoreVersion? = nil
    ) -> UUID? {
        guard !exclusiveBusy else {
            notice("凭据提取或本地解密正在运行，等它结束后再开始下载")
            return nil
        }
        guard self.credential(region: region, accountID: accountID) == credential else {
            notice("当前账号尚未绑定解密凭据，请先完成账号设置")
            return nil
        }
        guard canStartStoreJob else {
            notice("最多同时处理 \(maxParallelStoreJobs) 个 App，等其中一个完成后再添加")
            return nil
        }
        guard activeStoreJob(bundleId: item.bundleId, region: region, accountID: accountID) == nil else {
            notice("\(item.name) 已经在下载或解密")
            return nil
        }

        let work = Paths.scratch.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: work, withIntermediateDirectories: true)
        } catch {
            notice("创建下载临时目录失败：\(error.localizedDescription)")
            return nil
        }

        let total = version == nil ? item.bytes.flatMap { $0 > 0 ? $0 : nil } : nil
        var job = MacStoreJob(
            item: item, region: region, purchase: purchase, accountID: accountID,
            workDirectory: work,
            credentialURL: credential.url, credentialTitle: credential.title,
            requestedVersion: version)
        job.initialise(total: total)
        storeJobs.insert(job, at: 0)
        recordJobLog(job.id, "已加入离线任务（\(StoreRegion.title(region))，"
            + (purchase ? "免费软件，可自动取得许可" : "仅使用当前账号已有授权") + "）")
        if let version {
            recordJobLog(job.id, "所选版本 \(version.displayVersion)，ID \(version.externalVersionID)")
        }
        syncStoreSummary()

        let destination = work.appendingPathComponent("\(item.bundleId).ipa")
        let argv = AppModel.macOfflineStoreArgv(
            py: py.path, store: storeScript.path, item: item, dest: destination,
            ipatool: ipatool, cacheRoot: Paths.support.path, region: region,
            purchase: purchase, accountID: accountID,
            externalVersionID: version?.externalVersionID ?? "",
            expectedVersion: version?.displayVersion ?? "")
        Runner.stream(
            argv,
            onLine: { line in
                Task { @MainActor in self.consumeStoreDownload(job.id, line: line) }
            },
            onFinish: { code in
                Task { @MainActor in self.finishStoreDownload(job.id, code: code) }
            })
        return job.id
    }

    func storeJob(id: UUID) -> MacStoreJob? {
        storeJobs.first { $0.id == id }
    }

    func clearFinishedStoreJobs() {
        storeJobs.removeAll { !$0.state.isActive }
        syncStoreSummary()
    }

    private func consumeStoreDownload(_ id: UUID, line: String) {
        guard let data = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(EngineEvent.self, from: data) else {
            recordJobLog(id, line)
            return
        }
        switch event.e {
        case "progress":
            let done = Int64(max(0, event.done ?? 0))
            mutateStoreJob(id) { job in
                job.progressDone = max(job.progressDone, done)
                if let reportedTotal = event.total, reportedTotal > 0 {
                    job.progressTotal = Int64(reportedTotal)
                }
                if let total = job.progressTotal, total > 0 {
                    let fraction = min(0.995, Double(job.progressDone) / Double(total))
                    job.progressFraction = max(job.progressFraction ?? 0, fraction)
                    job.progressDetail =
                        "已下载 \(Self.byteText(job.progressDone)) / \(Self.byteText(total))"
                    job.stage = "正在下载 \(Self.percentText(job.progressFraction))"
                } else {
                    job.progressFraction = nil
                    job.progressDetail = job.progressDone > 0
                        ? "已下载 \(Self.byteText(job.progressDone))，正在等待 App Store 返回文件"
                        : "已连接 App Store，正在准备下载"
                    job.stage = "正在从 App Store 下载"
                }
            }
        case "result":
            guard let path = event.ipa, !path.isEmpty else { return }
            mutateStoreJob(id) { job in
                job.downloadedIPA = URL(fileURLWithPath: path)
                if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                   let number = attributes[.size] as? NSNumber {
                    job.progressDone = number.int64Value
                    job.progressTotal = number.int64Value
                }
                job.progressFraction = 1
                job.progressDetail =
                    "下载完成 \(Self.byteText(job.progressDone))，准备离线解密"
            }
        case "error":
            let message = event.m ?? "未知下载错误"
            mutateStoreJob(id) { job in
                job.progressFraction = nil
                job.progressDetail = message
                job.stage = "App Store 下载失败"
                job.failureMessage = message
            }
            recordJobLog(id, "错误：\(message)")
        case "log":
            recordJobLog(id, event.m ?? "")
            if event.phase == "download-retry" {
                mutateStoreJob(id) { job in
                    job.stage = "网络中断，正在重试下载"
                    job.progressDetail = event.m ?? "正在重新连接 App Store"
                }
            }
        default:
            recordJobLog(id, line)
        }
    }

    private func finishStoreDownload(_ id: UUID, code: Int32) {
        guard let job = storeJobs.first(where: { $0.id == id }) else { return }
        let expected = job.workDirectory
            .appendingPathComponent("\(job.item.bundleId).ipa")
        let ipa = job.downloadedIPA ?? expected
        guard code == 0, FileManager.default.fileExists(atPath: ipa.path) else {
            failStoreJob(
                id,
                message: job.failureMessage.isEmpty
                    ? "下载未完成，退出码 \(code)。请查看任务日志中的具体原因。"
                    : job.failureMessage)
            return
        }
        mutateStoreJob(id) { job in
            job.state = .decrypting
            job.downloadedIPA = ipa
            job.progressFraction = nil
            job.progressDetail = "下载完成，正在离线解密；应用较大时需要几分钟"
            job.stage = "准备离线解密"
        }
        recordJobLog(id, "下载完成：\(ipa.lastPathComponent)")
        startStoreDecrypt(id, ipa: ipa)
    }

    private func startStoreDecrypt(_ id: UUID, ipa: URL) {
        guard let job = storeJobs.first(where: { $0.id == id }) else { return }
        guard FileManager.default.fileExists(atPath: job.credentialURL.path) else {
            failStoreJob(id, message: "解密凭据文件已经不存在，请重新提取账号凭据")
            return
        }
        guard let runtime = fairplayRuntime() else {
            failStoreJob(id, message: "找不到 fairplay-decrypt 运行环境")
            return
        }
        let outDir = outputDirectory
        try? FileManager.default.createDirectory(
            at: outDir, withIntermediateDirectories: true)
        let provisional = outDir.appendingPathComponent(
            ".dumpshop-\(UUID().uuidString).ipa")
        let argv = Self.decryptArgv(
            tool: URL(fileURLWithPath: runtime.prefix[0]),
            input: ipa, output: provisional, credential: job.credentialURL)
        let actualArgv = runtime.prefix + ["decrypt"] + Array(argv.dropFirst())
        mutateStoreJob(id) { job in
            job.state = .decrypting
            job.progressFraction = nil
            job.progressDetail = "正在离线解密；应用较大时需要几分钟"
            job.stage = "读取 SINF/SUPF 并派生页面密钥"
        }
        recordJobLog(id, "开始离线解密，账号凭据：\(job.credentialTitle)")
        recordJobLog(id, "本次解密不需要手机在线")
        Runner.stream(
            actualArgv,
            environment: runtime.environment,
            onLine: { line in
                Task { @MainActor in self.consumeStoreDecrypt(id, line: line) }
            },
            onFinish: { code in
                Task { @MainActor in
                    await self.finishStoreDecrypt(
                        id, code: code, provisional: provisional, runtime: runtime)
                }
            })
    }

    private func consumeStoreDecrypt(_ id: UUID, line: String) {
        recordJobLog(id, line)
        mutateStoreJob(id) { job in
            if let hint = Self.credentialFailureHint(line) {
                job.failureMessage = hint
            }
            if let value = Self.logValue(after: "decrypted-binaries=", in: line),
               let count = Int(value) {
                job.encryptedImages = count
            }
            if let value = Self.logValue(after: "pages=", in: line),
               let pages = Int(value.split(separator: " ").first ?? "") {
                job.decryptedPages = pages
            }
        }
    }

    private func finishStoreDecrypt(
        _ id: UUID, code: Int32, provisional: URL, runtime: FairPlayRuntime
    ) async {
        guard let job = storeJobs.first(where: { $0.id == id }) else { return }
        guard code == 0, FileManager.default.fileExists(atPath: provisional.path) else {
            if !job.failureMessage.isEmpty, let ipa = job.downloadedIPA {
                await prepareRepairLicense(ipa: ipa, job: job)
            }
            failStoreJob(id, message: job.failureMessage.isEmpty
                ? "离线解密失败，fairplay-decrypt 退出码 \(code)"
                : job.failureMessage)
            try? FileManager.default.removeItem(at: provisional)
            return
        }
        mutateStoreJob(id) { job in
            job.state = .verifying
            job.progressFraction = nil
            job.progressDetail = "检查输出中是否还有加密 Mach-O"
            job.stage = "校验全解密结果"
        }
        let identity = await IPAIdentity.read(job.downloadedIPA ?? provisional)
        let verification = await Runner.run(
            runtime.prefix + ["verify", provisional.path],
            environment: runtime.environment, timeout: 900)
        let decoded = Self.decodeVerification(verification.out)
        let preferred = outputDirectory.appendingPathComponent(
            Self.outputName(identity: identity, verified: decoded?.allDecrypted))
        let destination = uniqueURL(preferred)
        do {
            try FileManager.default.moveItem(at: provisional, to: destination)
            mutateStoreJob(id) { job in
                job.state = .completed
                job.outputURL = destination
                job.verified = decoded?.allDecrypted
                job.encryptedImages = decoded?.machoImages ?? job.encryptedImages
                job.progressFraction = 1
                job.progressDetail = "全部完成，产物已保存到电脑"
                job.stage = decoded?.allDecrypted == true
                    ? "全解密并确认无残留 cryptid"
                    : "处理完成，请查看校验结果"
                job.finished = Date()
            }
            lastOutput = destination
            plaintextVerified = decoded?.allDecrypted
            decryptedPages = job.decryptedPages
            recordJobLog(id, "输出：\(destination.path)")
            recordJobLog(id, "共解密 \(job.decryptedPages) 页")
            cleanupStoreWork(id)
        } catch {
            try? FileManager.default.removeItem(at: provisional)
            failStoreJob(id, message: "移动产物失败：\(error.localizedDescription)")
        }
    }

    private func failStoreJob(_ id: UUID, message: String) {
        mutateStoreJob(id) { job in
            job.state = .failed
            job.progressFraction = nil
            job.progressDetail = message
            job.stage = "失败"
            job.finished = Date()
        }
        recordJobLog(id, "错误：\(message)")
        cleanupStoreWork(id)
    }

    private func prepareRepairLicense(ipa: URL, job: MacStoreJob) async {
        let listing = await Runner.run(["/usr/bin/unzip", "-Z1", ipa.path], timeout: 30)
        guard listing.ok else { return }
        let names = listing.out.split(separator: "\n").map(String.init).filter {
            let parts = $0.split(separator: "/")
            return parts.count == 4 && parts[0] == "Payload"
                && parts[1].hasSuffix(".app") && parts[2] == "SC_Info"
                && parts[3].hasSuffix(".sinf")
        }.sorted()
        guard let name = names.first(where: { !$0.hasSuffix(".v4.sinf") }) ?? names.first,
              let data = await Runner.data(["/usr/bin/unzip", "-p", ipa.path, name]),
              !data.isEmpty, data.count <= 1_048_576 else { return }
        let destination = repairLicenseDestination(region: job.region, accountID: job.accountID)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try data.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            recordJobLog(job.id, "已准备该账号的授权定位信息；连接越狱 iPhone 后，在设置中重新提取会自动使用。临时 IPA 仍会清理。")
        } catch {
            recordJobLog(job.id, "无法保存授权定位信息，请重新提取时手动选择对应账号的 IPA。")
        }
    }

    private func cleanupStoreWork(_ id: UUID) {
        guard let job = storeJobs.first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: job.workDirectory)
        recordJobLog(id, "已清理电脑上的临时加密 IPA")
    }

    private func mutateStoreJob(
        _ id: UUID, _ mutation: (inout MacStoreJob) -> Void
    ) {
        guard let index = storeJobs.firstIndex(where: { $0.id == id }) else { return }
        var job = storeJobs[index]
        mutation(&job)
        storeJobs[index] = job
        syncStoreSummary()
    }

    private func recordJobLog(_ id: UUID, _ line: String) {
        let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              let index = storeJobs.firstIndex(where: { $0.id == id }) else { return }
        var job = storeJobs[index]
        job.log.append(clean)
        if job.log.count > 900 {
            job.log.removeFirst(job.log.count - 900)
        }
        storeJobs[index] = job
        append("[\(job.item.name)] \(clean)")
    }

    private func syncStoreSummary() {
        let active = activeStoreJobs
        busy = exclusiveBusy || !active.isEmpty
        guard !active.isEmpty || !exclusiveBusy else { return }
        guard !active.isEmpty else {
            if storeJobs.contains(where: { $0.state == .completed }) {
                stage = "离线任务已完成，产物保存在电脑"
                progressDetail = "可以继续搜索并添加其他软件"
            }
            return
        }
        stage = active.count == 1
            ? active[0].stage
            : "正在并行处理 \(active.count) 个任务"
        progressDone = active.reduce(0) { $0 + $1.progressDone }
        let totals = active.compactMap(\.progressTotal)
        if totals.count == active.count {
            progressTotal = totals.reduce(0, +)
            if let total = progressTotal, total > 0 {
                progressFraction = min(0.995, Double(progressDone) / Double(total))
            } else {
                progressFraction = nil
            }
        } else {
            progressTotal = nil
            progressFraction = nil
        }
        progressDetail = active.count == 1
            ? active[0].progressDetail
            : "\(active.count) 个任务并行处理，可在任务卡片查看各自进度"
    }

    private func setExclusiveBusy(_ value: Bool) {
        exclusiveBusy = value
        busy = value || !activeStoreJobs.isEmpty
    }

    private func beginDecrypt(_ ipa: URL, removeAfterSuccess: Bool) {
        guard let credential = selectedCredential else {
            notice("还没有账号凭据，先连接越狱 iPhone 提取一次"); return
        }
        guard let runtime = fairplayRuntime() else {
            notice("找不到 fairplay-decrypt 运行环境"); return
        }
        let outDir = outputDirectory
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        inputIPA = ipa
        inputIdentity = nil
        setExclusiveBusy(true)
        lastOutput = nil
        plaintextVerified = nil
        encryptedImages = 0
        decryptedPages = 0
        removeTemporaryInput = removeAfterSuccess
        progressFraction = nil
        progressDetail = removeAfterSuccess
            ? "下载完成，正在离线解密；应用较大时需要几分钟"
            : "正在离线解密；应用较大时需要几分钟"
        let previousLog = removeAfterSuccess ? log : []
        log = previousLog + [
            "开始离线解密：\(ipa.lastPathComponent)",
            "账号凭据：\(credential.title)",
            "本次解密不需要手机在线。",
        ]
        stage = "读取 SINF/SUPF 并派生页面密钥"
        let provisional = outDir.appendingPathComponent(
            ".dumpshop-\(UUID().uuidString).ipa")
        let argv = Self.decryptArgv(
            tool: URL(fileURLWithPath: runtime.prefix[0]),
            input: ipa, output: provisional, credential: credential.url)
        let actualArgv = runtime.prefix + ["decrypt"] + Array(argv.dropFirst())
        Task {
            inputIdentity = await IPAIdentity.read(ipa)
            stage = "解密 FairPlay 页面并清理 cryptid"
            Runner.stream(
                actualArgv,
                environment: runtime.environment,
                onLine: { line in
                    Task { @MainActor in self.consumeDecrypt(line) }
                },
                onFinish: { code in
                    Task { @MainActor in
                        await self.finishDecrypt(
                            code: code,
                            provisional: provisional,
                            runtime: runtime)
                    }
                })
        }
    }

    nonisolated static func decryptArgv(
        tool: URL, input: URL, output: URL, credential: URL
    ) -> [String] {
        [tool.path, input.path, output.path, "--credential", credential.path]
    }

    nonisolated static func outputName(identity: IPAIdentity?, verified: Bool?) -> String {
        let name = filePart(identity?.name ?? "App")
        let version = filePart(identity?.version ?? "未知版本")
        let verdict: String
        switch verified {
        case true: verdict = "全解密"
        case false: verdict = "未完全解密"
        case nil: verdict = "未完全校验"
        }
        return "\(name)-\(version)-\(verdict).ipa"
    }

    func copyAllLogs() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(log.joined(separator: "\n"), forType: .string)
    }

    func revealOutput() {
        if let lastOutput {
            NSWorkspace.shared.activateFileViewerSelecting([lastOutput])
        }
    }

    func copyOutputPath() {
        guard let lastOutput else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lastOutput.path, forType: .string)
    }

    func deleteSelectedCredential() {
        guard let credential = selectedCredential else { return }
        guard !storeJobs.contains(where: { $0.state.isActive && $0.credentialURL == credential.url }) else {
            notice("此凭据正在用于任务，请等任务结束再删除")
            return
        }
        let parent = credential.url.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: parent)
        selectedCredentialPath = ""
        scanCredentials()
        credentialBindings = credentialBindings.filter { $0.value != credential.path }
        UserDefaults.standard.set(credentialBindings, forKey: "fairplay.credentialBindings")
        updateStage()
        append("已删除本机凭据：\(credential.label)")
    }

    private func finishExtraction(code: Int32, output: URL) {
        setExclusiveBusy(false)
        defer {
            try? FileManager.default.removeItem(at: output)
        }
        let extracted = output.appendingPathComponent("credential.bin")
        guard code == 0,
              let data = try? Data(contentsOf: extracted),
              data.count == 16 else {
            stage = "凭据提取失败"
            append("设备端提取没有完成，退出码 \(code)。")
            append("检查 SSH 端口、root 登录方式，以及手机上是否存在同账号 App Store 应用。")
            return
        }
        if let existing = credentials.first(where: { (try? Data(contentsOf: $0.url)) == data }) {
            selectedCredentialPath = existing.path
            stage = "提取结果与已有凭据相同"
            append("手机返回的凭据与已有凭据完全相同，未重复保存。")
            append("如需添加其他账号，请确认手机上安装了该账号取得授权的 App，并使用该账号的授权定位重新提取。改名不会生成新账号凭据。")
            return
        }
        let targetDir = Paths.fairplayCredentials.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: targetDir, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: targetDir.path)
            let credentialURL = targetDir.appendingPathComponent("credential.bin")
            try data.write(to: credentialURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: credentialURL.path)
            let metadata = CredentialMetadata(
                label: credentialLabel.trimmed.isEmpty ? "Apple 账号" : credentialLabel.trimmed,
                deviceName: selectedDevice?.name ?? "iPhone",
                deviceUDID: selectedDevice?.udid ?? selectedDeviceUDID,
                createdAt: Date())
            let info = try JSONEncoder().encode(metadata)
            try info.write(to: targetDir.appendingPathComponent("metadata.json"),
                           options: .atomic)
            scanCredentials()
            selectedCredentialPath = credentialURL.path
            stage = "凭据提取完成，可以脱离手机解密"
            append("已保存 16 字节账号凭据。")
            append("请为相同 Apple 账号的下载会话绑定这份凭据，之后即可拔掉手机。")
        } catch {
            stage = "保存凭据失败"
            append(error.localizedDescription)
        }
    }

    private func consumeDecrypt(_ line: String) {
        append(line)
        if let hint = Self.credentialFailureHint(line) { append(hint) }
        if let value = value(after: "decrypted-binaries=", in: line),
           let count = Int(value) {
            encryptedImages = count
        }
        if let value = value(after: "pages=", in: line),
           let pages = Int(value.split(separator: " ").first ?? "") {
            decryptedPages = pages
        }
    }

    nonisolated static func credentialFailureHint(_ line: String) -> String? {
        guard line.lowercased().contains("credential does not decode this sinf priv record") else {
            return nil
        }
        return "所选凭据无法解开此 IPA 的授权记录。常见原因是提取时使用了其他 Apple 账号的 App 授权。"
            + "请到设置 → 离线砸壳，用当前下载账号的 App 授权重新提取，选择正确凭据后点击保存。"
            + "账号名称只是备注，改名或切换地区不会改变凭据归属。"
    }

    private func finishDecrypt(
        code: Int32, provisional: URL, runtime: FairPlayRuntime
    ) async {
        defer {
            setExclusiveBusy(false)
            if removeTemporaryInput, let inputIPA {
                let parent = inputIPA.deletingLastPathComponent()
                try? FileManager.default.removeItem(at: inputIPA)
                try? FileManager.default.removeItem(at: parent)
                append("已清理电脑上的临时加密 IPA。")
            }
            removeTemporaryInput = false
        }
        guard code == 0, FileManager.default.fileExists(atPath: provisional.path) else {
            stage = "离线解密失败"
            progressFraction = nil
            progressDetail = "离线解密失败，请查看日志"
            append("fairplay-decrypt 退出码 \(code)。")
            try? FileManager.default.removeItem(at: provisional)
            return
        }
        if inputIdentity == nil, let ipa = inputIPA {
            inputIdentity = await IPAIdentity.read(ipa)
        }
        stage = "检查输出中是否还有加密 Mach-O"
        let verifyArgv = runtime.prefix + ["verify", provisional.path]
        let verification = await Runner.run(
            verifyArgv, environment: runtime.environment, timeout: 900)
        let decoded = Self.decodeVerification(verification.out)
        plaintextVerified = decoded?.allDecrypted
        if let decoded {
            encryptedImages = decoded.machoImages
        }
        let preferred = outputDirectory.appendingPathComponent(
            Self.outputName(identity: inputIdentity, verified: plaintextVerified))
        let destination = uniqueURL(preferred)
        do {
            try FileManager.default.moveItem(at: provisional, to: destination)
            lastOutput = destination
            switch plaintextVerified {
            case true:
                stage = "完成：全解密并确认无残留 cryptid"
                progressFraction = 1
                progressDetail = "全部完成，产物已保存到电脑"
                append("输出：\(destination.path)")
                append("扫描 \(encryptedImages) 个 Mach-O，未发现残留加密镜像。")
            case false:
                stage = "完成：仍有未解密的 Mach-O"
                progressFraction = 1
                progressDetail = "处理完成，但仍有未解密的 Mach-O"
                append("输出：\(destination.path)")
                append("输出 IPA 中仍有非零 cryptid，文件标记为“未完全解密”。")
            case nil:
                stage = "完成：解密命令成功，但完整性扫描失败"
                progressFraction = 1
                progressDetail = "处理完成，但完整性校验未通过"
                append("输出：\(destination.path)")
                append("未能解析扫描结果，文件标记为“未完全校验”。")
            }
            append("共解密 \(decryptedPages) 页。")
        } catch {
            stage = "解密完成，但整理产物失败"
            progressFraction = nil
            progressDetail = "整理输出文件失败，请查看日志"
            append("移动产物失败：\(error.localizedDescription)")
            lastOutput = provisional
        }
    }

    private struct FairPlayRuntime {
        let prefix: [String]
        let environment: [String: String]
    }

    private func fairplayRuntime() -> FairPlayRuntime? {
        if let helper = Paths.fairplayHelper() {
            helperURL = helper
            return FairPlayRuntime(prefix: [helper.path], environment: [:])
        }
        guard let script = Paths.fairplayScript(),
              let source = Paths.fairplaySource(),
              let python = Paths.fairplayPython() else {
            return nil
        }
        return FairPlayRuntime(
            prefix: [python, script.path],
            environment: ["FAIRPLAY_DECRYPT_SOURCE": source.path])
    }

    private func scanCredentials() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        var found: [FairPlayCredentialFile] = []
        if let dirs = try? fm.contentsOfDirectory(
            at: Paths.fairplayCredentials,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) {
            for dir in dirs {
                let url = dir.appendingPathComponent("credential.bin")
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true else { continue }
                let metadataURL = dir.appendingPathComponent("metadata.json")
                let metadata = (try? Data(contentsOf: metadataURL)).flatMap {
                    try? JSONDecoder().decode(CredentialMetadata.self, from: $0)
                }
                found.append(FairPlayCredentialFile(
                    url: url,
                    modified: values.contentModificationDate ?? metadata?.createdAt ?? .distantPast,
                    label: metadata?.label ?? "Apple 账号",
                    deviceName: metadata?.deviceName ?? ""))
            }
        }
        credentials = found.sorted { $0.modified > $1.modified }
        if !credentials.contains(where: { $0.path == selectedCredentialPath }) {
            selectedCredentialPath = credentials.first?.path ?? ""
        }
    }

    private func updateStage() {
        guard helperURL != nil || Paths.fairplayScript() != nil else {
            stage = "找不到 fairplay-decrypt 运行环境"
            return
        }
        if credentials.isEmpty && devices.isEmpty {
            stage = "首次使用：连接越狱 iPhone 提取一次账号凭据"
        } else if credentials.isEmpty {
            stage = "连接正常，首次需要提取账号凭据"
        } else {
            stage = "离线解密已就绪，无需连接手机"
        }
    }

    private func chooseIPA(_ save: (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "选择加密 IPA"
        panel.prompt = "选择 IPA"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa") ?? .data]
        if panel.runModal() == .OK, let url = panel.url { save(url) }
    }

    private func append(_ line: String) {
        let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        log.append(clean)
        if log.count > 900 {
            log.removeFirst(log.count - 900)
        }
    }

    private func notice(_ text: String) {
        stage = text
        append(text)
    }

    private func value(after marker: String, in line: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        return String(line[range.upperBound...])
    }

    nonisolated private static func decodeVerification(_ text: String) -> Verification? {
        for line in text.split(separator: "\n").reversed() {
            guard let data = String(line).data(using: .utf8),
                  let value = try? JSONDecoder().decode(Verification.self, from: data) else {
                continue
            }
            return value
        }
        return nil
    }

    private func uniqueURL(_ preferred: URL) -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: preferred.path) { return preferred }
        let ext = preferred.pathExtension
        let stem = preferred.deletingPathExtension().lastPathComponent
        for n in 2...999 {
            let candidate = preferred.deletingLastPathComponent()
                .appendingPathComponent("\(stem)-\(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return preferred.deletingLastPathComponent()
            .appendingPathComponent("\(stem)-\(UUID().uuidString.prefix(8)).ipa")
    }

    private func createPrivateDirectories() {
        for dir in [Paths.fairplayCredentials, Paths.fairplayStaging] {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
    }

    nonisolated private static func filePart(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let values = raw.unicodeScalars.map { invalid.contains($0) ? "_" : Character($0) }
        let clean = String(values).trimmingCharacters(
            in: CharacterSet(charactersIn: " ._-"))
        return clean.isEmpty ? "App" : String(clean.prefix(80))
    }

    nonisolated private static func byteText(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "0 B" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    nonisolated private static func percentText(_ fraction: Double?) -> String {
        guard let fraction else { return "下载中" }
        return "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    nonisolated private static func logValue(after marker: String, in line: String) -> String? {
        guard let range = line.range(of: marker) else { return nil }
        return String(line[range.upperBound...])
    }

    private struct CredentialMetadata: Codable {
        let label: String
        let deviceName: String
        let deviceUDID: String
        let createdAt: Date
    }

    private struct Verification: Decodable {
        let allDecrypted: Bool
        let machoImages: Int
        let encryptedImages: Int
        let filesScanned: Int

        enum CodingKeys: String, CodingKey {
            case allDecrypted = "all_decrypted"
            case machoImages = "macho_images"
            case encryptedImages = "encrypted_images"
            case filesScanned = "files_scanned"
        }
    }
}
