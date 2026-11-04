import Foundation

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let d = UserDefaults.standard
    private enum K {
        static let py = "pythonOverride"
        static let extra = "extraPythons"
        static let pass = "sshPass"
        static let engine = "engineSource"
        static let out = "outputDir"
        static let sys = "showSystemApps"
        static let pull = "pullMode"
        static let noResume = "noResume"
        static let autoUninstall = "autoUninstall"
        static let region = "storeRegion"
        static let storeUninstall = "storeAutoUninstall"
        static let ipatool = "ipatoolPath"
        static let pipIndex = "pipIndexURL"
        static let listMode = "listMode"
        static let maxParallel = "maxParallel"
        static let maxMacParallel = "maxMacParallel"
    }

    @Published var pythonOverride: String = ""
    @Published var extraPythons: [String] = []
    @Published var sshPass: String = "alpine"
    @Published var engineSource: String = ""
    @Published var outputDir: String = ""
    @Published var showSystemApps: Bool = false
    @Published var pullMode: String = "frida"
    @Published var noResume: Bool = false
    @Published var autoUninstall = false
    var keepOnDevice: Bool { !autoUninstall }
    @Published var storeRegion = "CN"
    /// Route B installs the app itself, so taking it back off afterwards is the
    /// tidy default; a pre-existing app is only removed when asked (autoUninstall).
    @Published var storeAutoUninstall = true
    @Published var ipatoolPath = ""
    /// Empty means official PyPI. A domestic mirror matters because PyPI's file host
    /// is throttled to a crawl from Chinese networks, which makes the first-run venv
    /// setup look like a hang.
    @Published var pipIndexURL = ""
    /// Raw value of `ListMode`; which catalogue the middle column last showed.
    @Published var listModeKey = ""
    /// How many dumps may run at once. One device, one USB bus, so the useful
    /// range is small; each extra job also needs its own space on the phone.
    @Published var maxParallel = 2
    @Published var maxMacParallel = 3

    private init() {
        d.register(defaults: [K.pass: "alpine", K.pull: "frida", K.region: "CN"])
        pythonOverride = d.string(forKey: K.py) ?? ""
        extraPythons = d.stringArray(forKey: K.extra) ?? []
        sshPass = d.string(forKey: K.pass) ?? "alpine"
        engineSource = d.string(forKey: K.engine) ?? ""
        outputDir = d.string(forKey: K.out) ?? ""
        showSystemApps = d.bool(forKey: K.sys)
        pullMode = d.string(forKey: K.pull) ?? "frida"
        noResume = d.bool(forKey: K.noResume)
        autoUninstall = d.bool(forKey: K.autoUninstall)
        storeRegion = d.string(forKey: K.region) ?? "CN"
        storeAutoUninstall = d.object(forKey: K.storeUninstall) as? Bool ?? true
        ipatoolPath = d.string(forKey: K.ipatool) ?? ""
        pipIndexURL = d.string(forKey: K.pipIndex) ?? ""
        listModeKey = d.string(forKey: K.listMode) ?? ""
        maxParallel = (d.object(forKey: K.maxParallel) as? Int) ?? 2
        if maxParallel < 1 || maxParallel > 6 { maxParallel = 2 }
        maxMacParallel = max(1, (d.object(forKey: K.maxMacParallel) as? Int) ?? 3)
    }

    func save() {
        d.set(pythonOverride, forKey: K.py)
        d.set(extraPythons, forKey: K.extra)
        d.set(sshPass, forKey: K.pass)
        d.set(engineSource, forKey: K.engine)
        d.set(outputDir, forKey: K.out)
        d.set(showSystemApps, forKey: K.sys)
        d.set(pullMode, forKey: K.pull)
        d.set(noResume, forKey: K.noResume)
        d.set(autoUninstall, forKey: K.autoUninstall)
        d.set(storeRegion, forKey: K.region)
        d.set(storeAutoUninstall, forKey: K.storeUninstall)
        d.set(ipatoolPath, forKey: K.ipatool)
        d.set(pipIndexURL, forKey: K.pipIndex)
        d.set(listModeKey, forKey: K.listMode)
        d.set(maxParallel, forKey: K.maxParallel)
        d.set(maxMacParallel, forKey: K.maxMacParallel)
    }

    var resolvedOutDir: URL {
        if !outputDir.isEmpty { return URL(fileURLWithPath: outputDir) }
        return Paths.dumps
    }
}
