import Foundation

/// Which catalogue the middle column shows. The raw values are stable keys so the
/// choice can be remembered across launches without depending on the wording.
enum ListMode: String, CaseIterable, Identifiable {
    case device
    case store
    var id: String { rawValue }
    var title: String {
        switch self {
        case .device: return "手机已装"
        case .store: return "App Store"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var devices: [IOSDevice] = []
    @Published var selectedUDID: String? = nil
    @Published var apps: [InstalledApp] = []
    @Published var icons: [String: Data] = [:]
    @Published var catalogNote = ""
    @Published var deviceSource = ""
    @Published var listMode: ListMode = .device
    @Published var jobs: [DumpJob] = []
    @Published var selectedAppID: String? = nil
    /// Multi-selection, so a batch of apps can be queued in one go.
    @Published var selectedAppIDs: Set<String> = []
    /// argv for jobs that are queued but not started yet.
    var pendingArgv: [UUID: [String]] = [:]
    @Published var sidebarSel: SidebarItem? = nil
    @Published var sizes: [String: Int64] = [:]
    @Published var busy = false
    @Published var notice: String? = nil
    @Published var actionsLog: [String] = []
    @Published var lastRefresh: Date? = nil
    @Published var settingsPage: SettingsPage = .general
    @Published var settingsRequestID = UUID()
    @Published var filterDumpable = true

    // Route B: App Store catalogue and the persistent download session.
    @Published var storeResults: [StoreItem] = []
    @Published var storeArt: [Int: Data] = [:]
    @Published var selectedStoreID: Int? = nil
    @Published var storeBusy = false
    @Published var storeNote = ""
    @Published var storeRegion = AppSettings.shared.storeRegion
    @Published var storeAuthByRegion: [String: StoreAuth] = [:]
    var storeSearchGeneration = UUID()
    var storeAuthGeneration: [String: UUID] = [:]

    let env = Env.shared
    let settings = AppSettings.shared
    let macFairPlay = MacFairPlayController()

    private var timer: Timer?
    private var probing = false
    private var refreshStarted = Date.distantPast
    private var engineDir: URL? = nil

    var selectedDevice: IOSDevice? {
        if case .device(let u) = sidebarSel { return devices.first { $0.udid == u } ?? devices.first }
        return devices.first { $0.udid == selectedUDID } ?? devices.first
    }
    var hasConnectedDevice: Bool { !devices.isEmpty }

    var selectedJob: DumpJob? {
        if case .job(let id) = sidebarSel { return jobs.first { $0.id == id } }
        return nil
    }
    var selectedStoreJob: MacStoreJob? {
        if case .storeJob(let id) = sidebarSel {
            return macFairPlay.storeJob(id: id)
        }
        return nil
    }
    var selectedApp: InstalledApp? {
        // With a batch selected there is no single app to describe, so the detail
        // column switches to the batch card instead of guessing one.
        selectedAppIDs.count == 1 ? selectedApps.first : nil
    }
    var selectedApps: [InstalledApp] {
        apps.filter { selectedAppIDs.contains($0.bundleId) }
    }
    var selectedDumpableApps: [InstalledApp] {
        selectedApps.filter { $0.dumpable }
    }
    var selectedStoreItem: StoreItem? {
        storeResults.first { $0.id == selectedStoreID }
    }
    var storeAuth: StoreAuth {
        storeAuthByRegion[storeRegion] ?? StoreAuth()
    }
    /// The same bundle id already on the phone, if the user has it installed.
    func installedMatch(_ item: StoreItem) -> InstalledApp? {
        apps.first { $0.bundleId == item.bundleId }
    }
    var activeJob: DumpJob? {
        jobs.first { $0.state == .running || $0.state == .queued }
    }
    var runningJobs: [DumpJob] { jobs.filter { $0.state == .running } }
    var queuedJobs: [DumpJob] { jobs.filter { $0.state == .queued } }
    var runningCount: Int { runningJobs.count }
    var hasWaitingWork: Bool { !queuedJobs.isEmpty }
    /// A free slot, not "nothing at all is running": batching depends on this.
    var canStartMore: Bool { runningCount < max(1, settings.maxParallel) }

    func start() {
        engineDir = Paths.engineDir(source: settings.engineSource)
        let savedMode = ListMode(rawValue: settings.listModeKey) ?? .store
        listMode = devices.isEmpty && savedMode == .device ? .store : savedMode
        env.reprobe()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            Task { @MainActor in await AppModel.shared.watchPresence() }
        }
    }

    func selectStoreRegion(_ code: String) {
        let region = StoreRegion.code(code)
        guard storeRegion != region else { refreshStoreAuth(region: region); return }
        storeSearchGeneration = UUID()
        storeResults = []
        selectedStoreID = nil
        storeBusy = false
        storeNote = ""
        storeRegion = region
        settings.storeRegion = region
        settings.save()
        refreshStoreAuth(region: region)
    }

    func presentSettings(_ page: SettingsPage) {
        settingsPage = page
        settingsRequestID = UUID()
    }

    /// Only looks at which devices usbmuxd can see. It never touches the app
    /// list, so the list stays put; plugging the phone in still works because a
    /// connect or disconnect is exactly what triggers a real refresh.
    func watchPresence() async {
        guard !probing else { return }
        guard let exe = Tool.which("idevice_id") else { return }
        var seen: Set<String> = []
        for arg in ["-l", "-n"] {
            let r = await Runner.run([exe, arg], timeout: 10)
            for raw in r.out.split(separator: "\n") {
                let u = String(raw).trimmed
                if !u.isEmpty { seen.insert(u) }
            }
        }
        if seen != Set(devices.map(\.udid)) { refresh() }
    }

    // MARK: - discovery

    /// Explicit refresh only: toolbar, Cmd-R, or a device appearing/disappearing.
    func refresh(quiet: Bool = false) {
        // A wedged child must never leave the app permanently unrefreshable.
        if probing, Date().timeIntervalSince(refreshStarted) > 150 { probing = false }
        guard !probing else { return }
        probing = true
        refreshStarted = Date()
        Task {
            await sweep()
            await probeAll()
            if let udid = selectedUDID { await loadApps(udid: udid) }
            probing = false
        }
    }

    /// Fast pass: what usbmuxd can see right now. Publishes immediately so the
    /// sidebar never waits on slower probing to show the phone.
    private func sweep() async {
        var found: [String: IOSDevice] = [:]
        // pymobiledevice3 needs no Homebrew install, so it is the portable path.
        if let viaPy = await viaDevicesList(), !viaPy.isEmpty {
            for d in viaPy { found[d.udid] = d }
            deviceSource = "pymobiledevice3"
        }
        if let exe = Tool.which("idevice_id"), found.isEmpty {
            for net in [false, true] {
                let args = net ? ["-n"] : ["-l"]
                let r = await Runner.run([exe] + args, timeout: 15)
                for raw in r.out.split(separator: "\n") {
                    let u = String(raw).trimmed
                    guard !u.isEmpty else { continue }
                    if let keep = devices.first(where: { $0.udid == u }) {
                        var d = keep
                        if net { d.viaNetwork = true }
                        found[u] = d
                    } else {
                        found[u] = IOSDevice(udid: u, viaNetwork: net)
                    }
                }
            }
        }
        for key in found.keys where found[key]?.name == "未知设备" {
            found[key] = await fill(udid: key, base: found[key]!)
        }
        // Drop devices that vanished.
        devices = found.values.sorted { $0.name < $1.name }
        if devices.isEmpty {
            if listMode == .device {
                listMode = .store
                selectedAppIDs = []
            }
            if case .device = sidebarSel { sidebarSel = nil }
        }
        if let sel = selectedUDID, !found.keys.contains(sel) {
            selectedUDID = devices.first?.udid
        } else if selectedUDID == nil {
            selectedUDID = devices.first?.udid
        }
        lastRefresh = Date()
    }

    /// Slow pass: ask frida whether each device can really be injected into.
    private func probeAll() async {
        guard env.py.ready, let dir = engineDirURL else { return }
        let py = env.py.path!
        let script = dir.appendingPathComponent("probe.py").path
        for dev in devices {
            guard let idx = devices.firstIndex(where: { $0.udid == dev.udid }) else { continue }
            let r = await Runner.run([py, script, "--udid", dev.udid, "--timeout", "6"],
                                     timeout: 45)
            guard let line = r.out.split(separator: "\n").first,
                  let data = line.data(using: .utf8),
                  let ev = try? JSONDecoder().decode(ProbeRow.self, from: data) else {
                devices[idx].fridaVisible = false
                devices[idx].injectable = false
                continue
            }
            devices[idx].fridaVisible = true
            devices[idx].injectable = ev.injectable
            devices[idx].enumerateOK = ev.enumerateOK ?? false
            devices[idx].ddiRequired = ev.ddiRequired ?? false
            devices[idx].needsFridaServer = ev.needsFridaServer ?? false
            devices[idx].fridaError = ev.error
            devices[idx].appCount = ev.appCount ?? 0
            if let v = ev.ios, devices[idx].version == "?" { devices[idx].version = v }
        }
    }

    private func fill(udid: String, base: IOSDevice) async -> IOSDevice {
        var d = base
        guard let exe = Tool.which("ideviceinfo") else { return d }
        let wanted = ["DeviceName", "ProductType", "ProductVersion", "ProductName",
                      "ActivationState"]
        var vals: [String: String] = [:]
        for key in wanted {
            let r = await Runner.run([exe, "-u", udid, "-k", key], timeout: 20)
            let v = r.out.trimmed
            if r.ok && !v.isEmpty { vals[key] = v }
        }
        d.name = vals["DeviceName"] ?? d.name
        d.productType = vals["ProductType"] ?? d.productType
        d.version = vals["ProductVersion"] ?? d.version
        if let p = vals["ProductName"] { d.systemName = p }
        d.paired = vals["ActivationState"] == "Activated"
        return d
    }

    private struct ProbeRow: Decodable {
        let udid: String
        let injectable: Bool
        var enumerateOK: Bool?
        var ddiRequired: Bool?
        var needsFridaServer: Bool?
        var ios: String?
        var error: String?
        var appCount: Int?

        private enum CodingKeys: String, CodingKey {
            case udid, injectable, ios, error
            case appCount = "app_count"
            case enumerateOK = "enumerate_ok"
            case ddiRequired = "ddi_required"
            case needsFridaServer = "needs_frida_server"
        }
    }

    private func viaDevicesList() async -> [IOSDevice]? {
        guard let py = env.py.path, let dir = engineDirURL else { return nil }
        let script = dir.appendingPathComponent("devices.py").path
        let r = await Runner.run([py, script, "list"], timeout: 90)
        var out: [IOSDevice] = []
        for line in r.out.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let row = try? JSONDecoder().decode(DeviceRow.self, from: d),
                  row.e == "device", !row.udid.isEmpty else { continue }
            var dev = IOSDevice(udid: row.udid)
            dev.name = row.name.isEmpty ? "未命名设备" : row.name
            dev.productType = row.product_type
            dev.version = row.version
            dev.systemName = row.connection == "Network" ? "iOS (网络)" : "iOS"
            dev.paired = row.paired
            dev.viaNetwork = row.connection != "USB"
            out.append(dev)
        }
        return out
    }

    private struct DeviceRow: Decodable {
        let e: String
        let udid: String
        let name: String
        let product_type: String
        let version: String
        let paired: Bool
        let connection: String
    }

    // MARK: - app catalog

    func loadApps(udid: String) async {
        busy = true
        defer { busy = false }
        guard let dev = devices.first(where: { $0.udid == udid }) else { return }
        var merged: [String: InstalledApp] = [:]
        var notes: [String] = []

        if let list = await viaDevicesApps(udid), !list.isEmpty {
            for a in list { merged[a.bundleId] = a }
            notes.append("pymobiledevice3 \(list.count)")
        } else if let list = await viaInstaller(udid), !list.isEmpty {
            for a in list { merged[a.bundleId] = a }
            notes.append("ideviceinstaller \(list.count)")
        }
        // Enumerating apps only needs a mounted Developer Image, so use frida
        // for breadth and icons even before frida-server is in place.
        if dev.enumerateOK, let list = await viaFrida(udid), !list.isEmpty {
            for a in list {
                if var old = merged[a.bundleId] {
                    if old.path.isEmpty { old.path = a.path }
                    if old.shortVersion == "?" { old.shortVersion = a.shortVersion }
                    if old.name == old.bundleId { old.name = a.name }
                    old.running = a.running
                    merged[a.bundleId] = old
                } else {
                    merged[a.bundleId] = a
                }
            }
            notes.append("frida \(list.count)")
        }
        if merged.isEmpty, let r = await viaInstallerAll(udid) {
            for a in r { merged[a.bundleId] = a }
            notes.append("installer-all \(r.count)")
        }

        let next = Array(merged.values)
            .filter { settings.showSystemApps || $0.kind != .system }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if next != apps { apps = next }
        let note = notes.isEmpty ? "读不到应用列表" : notes.joined(separator: " + ")
        if note != catalogNote { catalogNote = note }
        if let sel = selectedAppID, !merged.keys.contains(sel) { selectedAppID = nil }
        // Drop selections that no longer exist so a batch never targets a ghost.
        let alive = Set(merged.keys)
        let pruned = selectedAppIDs.intersection(alive)
        if pruned != selectedAppIDs { selectedAppIDs = pruned }
        refreshSizes(for: dev)
    }

    /// Sizes come from one root `du` sweep, which takes ~10s on a full phone, so
    /// it runs detached and never blocks the list from appearing.
    private func refreshSizes(for dev: IOSDevice) {
        guard dev.injectable, env.py.ready,
              let py = env.py.path, let dir = engineDirURL else { return }
        let udid = dev.udid
        Task {
            let script = dir.appendingPathComponent("appsize.py").path
            let r = await Runner.run([py, script, "--udid", udid, "--python-hint", py],
                                     timeout: 300)
            var map: [String: Int64] = [:]
            for line in r.out.split(separator: "\n") {
                guard let d = line.data(using: .utf8),
                      let ev = try? JSONDecoder().decode(SizeRow.self, from: d),
                      ev.e == "size" else { continue }
                map[ev.path] = ev.kb
            }
            guard !map.isEmpty else { return }
            sizes.merge(map) { _, new in new }
            apps = apps.map { app in
                var copy = app
                if let kb = sizes[app.path], copy.sizeKB != kb { copy.sizeKB = kb }
                return copy
            }
        }
    }

    private struct SizeRow: Decodable {
        let e: String
        let path: String
        let kb: Int64
    }

    private func viaDevicesApps(_ udid: String) async -> [InstalledApp]? {
        guard let py = env.py.path, let dir = engineDirURL else { return nil }
        let script = dir.appendingPathComponent("devices.py").path
        let r = await Runner.run([py, script, "apps", "--udid", udid], timeout: 240)
        var out: [InstalledApp] = []
        for line in r.out.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let row = try? JSONDecoder().decode(AppRow.self, from: d),
                  row.e == "app" else { continue }
            out.append(InstalledApp(bundleId: row.bundle_id, name: row.name,
                                    executable: row.executable, shortVersion: row.version,
                                    buildVersion: row.build, path: row.path,
                                    container: row.container,
                                    kind: SourceKind(fromEngine: row.kind)))
        }
        return out.isEmpty ? nil : out
    }

    private struct AppRow: Decodable {
        let e: String
        let bundle_id: String
        let name: String
        let executable: String
        let version: String
        let build: String
        let path: String
        let container: String
        let kind: String
    }

    private func viaInstaller(_ udid: String) async -> [InstalledApp]? {
        guard let exe = Tool.which("ideviceinstaller") else { return nil }
        let r = await Runner.run([exe, "-u", udid, "list", "--user", "--xml"], timeout: 200)
        return parse(r.out)
    }

    private func viaInstallerAll(_ udid: String) async -> [InstalledApp]? {
        guard let exe = Tool.which("ideviceinstaller") else { return nil }
        let r = await Runner.run([exe, "-u", udid, "list", "--all", "--xml"], timeout: 200)
        return parse(r.out)
    }

    private func parse(_ xml: String) -> [InstalledApp]? {
        guard let data = xml.data(using: .utf8),
              let top = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [[String: Any]] else { return nil }
        return top.compactMap { InstalledApp($0) }
    }

    private func viaFrida(_ udid: String) async -> [InstalledApp]? {
        guard let py = env.py.path, let dir = engineDir else { return nil }
        let script = dir.appendingPathComponent("applist.py").path
        let r = await Runner.run([py, script, "--udid", udid], timeout: 300)
        var out: [InstalledApp] = []
        for line in r.out.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let row = try? JSONDecoder().decode(FridaRow.self, from: d),
                  row.e == "app" else { continue }
            if let b64 = row.iconB64, let data = Data(base64Encoded: b64) {
                icons[row.bundleId] = data
            }
            out.append(InstalledApp(bundleId: row.bundleId, name: row.name,
                                    shortVersion: row.version, buildVersion: row.build,
                                    path: row.path, container: row.container,
                                    running: row.pid > 0))
        }
        return out
    }

    private struct FridaRow: Decodable {
        let e: String
        let bundleId: String
        let name: String
        let version: String
        let build: String
        let path: String
        let container: String
        let pid: Int
        let system: Bool
        var iconB64: String?
        enum CodingKeys: String, CodingKey {
            case e, name, version, build, path, container, pid, system
            case bundleId = "bundle_id"
            case iconB64 = "icon_b64"
        }
    }
}
