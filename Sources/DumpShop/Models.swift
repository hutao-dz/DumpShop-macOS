import Foundation

enum SidebarItem: Hashable {
    case device(String)
    case job(UUID)
    case storeJob(UUID)
}

enum SourceKind: String {
    case appStore = "App Store 加密"
    case plain = "未加密/自签"
    case system = "系统"
    case unknown = "未知"

    init(fromEngine raw: String) {
        switch raw {
        case "appStore": self = .appStore
        case "plain": self = .plain
        case "system": self = .system
        default: self = .unknown
        }
    }

    /// App Store builds carry this exact signer string and are FairPlay wrapped;
    /// anything else (TrollStore, esign, dev-signed) ships plaintext Mach-Os.
    static func classify(path: String, bundleId: String, signer: String?) -> SourceKind {
        if bundleId.hasPrefix("com.apple.") || path.hasPrefix("/Applications/") { return .system }
        if let s = signer, s.contains("Apple iPhone OS Application Signing") { return .appStore }
        return .plain
    }

    var tint: String {
        switch self {
        case .appStore: return "orange"
        case .plain: return "green"
        case .system: return "gray"
        case .unknown: return "gray"
        }
    }
}

struct InstalledApp: Identifiable, Hashable {
    var id: String { bundleId }
    let bundleId: String
    var name: String
    var executable: String
    var shortVersion: String
    var buildVersion: String
    var path: String
    var container: String
    var kind: SourceKind
    var running: Bool
    var sizeKB: Int64

    init(bundleId: String, name: String, executable: String = "", shortVersion: String = "?",
         buildVersion: String = "", path: String = "", container: String = "",
         kind: SourceKind = .unknown, running: Bool = false, sizeKB: Int64 = 0) {
        self.bundleId = bundleId
        self.name = name
        self.executable = executable
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.path = path
        self.container = container
        self.kind = kind
        self.running = running
        self.sizeKB = sizeKB
    }

    /// Build from one `ideviceinstaller list --xml` record.
    init?(_ raw: [String: Any]) {
        guard let bundleId = raw["CFBundleIdentifier"] as? String, !bundleId.isEmpty else { return nil }
        let path = (raw["Path"] as? String) ?? ""
        self.init(
            bundleId: bundleId,
            name: (raw["CFBundleDisplayName"] as? String) ?? (raw["CFBundleName"] as? String) ?? bundleId,
            executable: (raw["CFBundleExecutable"] as? String) ?? "",
            shortVersion: (raw["CFBundleShortVersionString"] as? String)
                ?? (raw["CFBundleVersion"] as? String) ?? "?",
            buildVersion: (raw["CFBundleVersion"] as? String) ?? "",
            path: path,
            container: (raw["Container"] as? String) ?? "",
            kind: SourceKind.classify(path: path, bundleId: bundleId,
                                     signer: raw["SignerIdentity"] as? String))
    }

    var dumpable: Bool { kind == .appStore }

    var sizeText: String {
        guard sizeKB > 0 else { return "" }
        let mb = Double(sizeKB) / 1024.0
        return mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
    var appFolderName: String { (path as NSString).lastPathComponent }
}

struct IOSDevice: Identifiable, Hashable {
    var id: String { udid }
    let udid: String
    var name = "未知设备"
    var productType = "?"
    var systemName = "iOS"
    var version = "?"
    var paired = false
    var viaNetwork = false

    var fridaVisible = false
    /// Developer Image mounted: frida can list apps/processes.
    var enumerateOK = false
    /// frida-server running: frida can actually attach. Required to dump.
    var injectable = false
    var ddiRequired = false
    var needsFridaServer = false
    var fridaError: String? = nil
    var appCount = 0

    var jailbreakKind: String? = nil

    var subtitle: String { "\(systemName) \(version) · \(productType)" }

    var shortUDID: String {
        udid.count > 12 ? String(udid.prefix(8)) + "…" + String(udid.suffix(4)) : udid
    }

    var needsDDI: Bool { ddiRequired }
    var readyToDump: Bool { injectable }

    /// What the user has to do next, in plain words.
    var blocker: String? {
        if injectable { return nil }
        if !fridaVisible { return "还没探测过这台设备" }
        if ddiRequired { return "需要挂载 Developer Disk Image" }
        if needsFridaServer { return "设备上缺少 frida-server" }
        return fridaError ?? "没有可用的注入通道"
    }
}

struct DumpResult {
    let ipa: URL
    let app: String
    let bundleId: String
    let version: String
    let binaries: Int
    let stillEncrypted: [String]
    let mb: Double
    let seconds: Double
    /// Name of the main executable, reported by the engine; the app list may not know it.
    let exe: String
}

enum JobState: String {
    case queued = "排队中", running = "进行中", succeeded = "完成", failed = "失败"
}

struct DumpJob: Identifiable {
    let id = UUID()
    let udid: String
    let deviceName: String
    let app: InstalledApp
    /// Where the package came from: an app already on the phone, or Route B.
    var origin: JobOrigin = .device
    var storeNote = ""
    var state: JobState = .queued
    var stage = "等待开始"
    var fraction: Double? = nil
    var phaseNote = ""
    var log: [String] = []
    var result: DumpResult? = nil
    var verifyNote = ""
    let started = Date()
    var finished: Date? = nil
}

enum JobOrigin: String {
    case device = "手机已装"
    case store = "App Store 下载"
}

/// NDJSON records emitted by dumper.py.
struct EngineEvent: Decodable {
    let e: String
    var n: String?
    var name: String?
    var m: String?
    var level: String?
    var phase: String?
    var done: Double?
    var total: Double?
    var filesDone: Double?
    var filesTotal: Double?
    var current: String?
    var ipa: String?
    var app: String?
    var version: String?
    var binaries: Int?
    var mb: Double?
    var seconds: Double?
    var stillEncrypted: [String]?
    var bundleId: String?
    var count: Int?
    var exe: String?
    var binary: Bool?
    var loggedIn: Bool?
    var email: String?
    var source: String?
    var error: String?
    var ipatool: String?
    var accountID: String?
    var region: String?

    private enum CodingKeys: String, CodingKey {
        case e, n, name, m, level, phase, done, total, current, ipa, app, version
        case binaries, mb, seconds, count
        case exe, binary, email, source, error, ipatool, region
        case accountID = "account_id"
        case filesDone = "files_done"
        case filesTotal = "files_total"
        case bundleId = "bundle_id"
        case stillEncrypted = "still_encrypted"
        case loggedIn = "logged_in"
    }
}
