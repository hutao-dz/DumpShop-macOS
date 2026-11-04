import AppKit
import SwiftUI

// MARK: - root

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        WorkshopView()
        .onChange(of: model.settingsRequestID) { _, _ in
            openSettings()
        }
        .task { if !model.storeAuth.loggedIn { model.refreshStoreAuth() } }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
                model.refreshStoreAuth()
            }
        .onChange(of: model.listMode) { _, mode in
            if mode == .store { model.refreshStoreAuth() }
            // Remember which catalogue the user was looking at.
            model.settings.listModeKey = mode.rawValue
            model.settings.save()
        }
        // The interpreter probe lands after launch, so retry the store check once it
        // does rather than leaving the panel claiming ipatool is missing.
        .onChange(of: model.env.py.path) { _, found in
            if found != nil { model.refreshStoreAuth() }
        }

    }
}

// MARK: - devices

struct DeviceSidebar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var mac = AppModel.shared.macFairPlay

    var body: some View {
        List(selection: $model.sidebarSel) {
            if model.hasConnectedDevice {
                Section("设备") {
                    ForEach(model.devices) { dev in
                        DeviceRow(dev: dev).tag(SidebarItem.device(dev.udid))
                    }
                }
            }
            Section("任务") {
                if model.jobs.isEmpty && mac.storeJobs.isEmpty {
                    Text("还没有任务").font(.callout).foregroundStyle(.tertiary)
                }
                ForEach(mac.storeJobs) { job in
                    MacStoreJobSidebarRow(job: job)
                        .tag(SidebarItem.storeJob(job.id))
                        .contextMenu {
                            if let output = job.outputURL {
                                Button("在访达中显示") {
                                    NSWorkspace.shared.activateFileViewerSelecting([output])
                                }
                                Button("复制 IPA 路径") {
                                    model.copy(output.path)
                                }
                            }
                            Button("复制全部日志") {
                                model.copy(job.log.joined(separator: "\n"))
                            }
                        }
                }
                ForEach(model.jobs) { job in
                    JobRow(job: job)
                        .tag(SidebarItem.job(job.id))
                        .contextMenu {
                            if let ipa = job.result?.ipa {
                                Button("在访达中显示") { model.reveal(ipa) }
                                Button("复制 IPA 路径") { model.copy(ipa.path) }
                            }
                            Divider()
                            Button("复制全部日志") { model.copy(job.log.joined(separator: "\n")) }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: model.sidebarSel) { _, sel in
            if case .device(let u) = sel { model.selectedUDID = u }
        }
    }
}

struct DeviceRow: View {
    let dev: IOSDevice
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "iphone.gen3")
                    .foregroundStyle(dev.injectable ? .teal : .secondary)
                Text(dev.name).fontWeight(.medium).lineLimit(1)
                Spacer(minLength: 4)
                StatusDot(ok: dev.injectable)
            }
            Text(dev.subtitle)
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            HStack(spacing: 5) {
                chip(dev.injectable ? "可注入"
                     : (!dev.fridaVisible ? "未检测"
                        : (dev.ddiRequired ? "缺 DDI"
                           : (dev.needsFridaServer ? "缺 frida-server" : "无通道"))),
                     tone: dev.injectable ? .ok : (dev.fridaVisible ? .warn : .mute))
                if dev.appCount > 0 {
                    Text("\(dev.appCount) 个应用")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
        .simultaneousGesture(TapGesture().onEnded {
            if case .storeJob = model.sidebarSel { model.sidebarSel = nil }
        })
        .contextMenu {
            if dev.ddiRequired || !dev.enumerateOK {
                Button("挂载 Developer Image") { model.mountDDI() }
            }
            Button("准备 frida-server") { model.prepareFridaServer() }
            Button("复制 UDID") { model.copy(dev.udid) }
        }
    }
}

struct StatusDot: View {
    let ok: Bool
    var body: some View {
        Circle().fill(ok ? Color.green : Color.orange).frame(width: 7, height: 7)
    }
}

enum ChipTone { case ok, warn, info, mute
    var color: Color { switch self {
        case .ok: return .green; case .warn: return .orange
        case .info: return .teal; case .mute: return .secondary } }
}

struct Chip: View {
    let text: String
    var tone: ChipTone = .mute
    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tone.color.opacity(0.14), in: Capsule())
            .foregroundStyle(tone.color)
            .overlay(Capsule().stroke(tone.color.opacity(0.35), lineWidth: 0.5))
    }
}

func chip(_ t: String, tone: ChipTone) -> Chip { Chip(text: t, tone: tone) }

struct JobRow: View {
    let job: DumpJob
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(color)
                    .symbolEffect(.variableColor, isActive: job.state == .running)
                Text(job.app.name).lineLimit(1)
                Spacer(minLength: 4)
                if job.state == .running, let f = job.fraction {
                    Text("\(Int(f * 100))%").font(.caption2).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if job.state == .queued {
                    Button { model.cancelQueued(job.id) } label: {
                        Image(systemName: "xmark.circle").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("从队列移除")
                }
            }
            .font(.callout)
            if job.state == .running {
                ProgressView(value: job.fraction ?? 0).controlSize(.mini)
            }
            Text(subline).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var subline: String {
        switch job.state {
        case .succeeded:
            if let r = job.result {
                return String(format: "%.1f MB · 点击查看日志", r.mb)
            }
            return "完成 · 点击查看日志"
        case .failed:
            return "失败 · 点击查看日志"
        case .running:
            return job.stage
        case .queued:
            let ahead = model.queuedJobs.filter { $0.started < job.started }.count
            return ahead == 0 ? "排队中 · 下一个" : "排队中 · 前面还有 \(ahead) 个"
        }
    }

    private var symbol: String {
        switch job.state {
        case .running: return "circle.circle.dashed"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .queued: return "clock"
        }
    }
    private var color: Color {
        switch job.state {
        case .succeeded: return .green
        case .failed: return .red
        case .running: return .teal
        case .queued: return .secondary
        }
    }
}

private struct MacStoreJobSidebarRow: View {
    let job: MacStoreJob

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                    .frame(width: 15)
                Text(job.item.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if job.state.isActive, let fraction = job.progressFraction {
                    Text("\(Int((min(max(fraction, 0), 1) * 100).rounded()))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text("\(job.state.rawValue) · \(job.stage)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if job.state.isActive {
                if let fraction = job.progressFraction {
                    ProgressView(value: min(max(fraction, 0), 1))
                        .controlSize(.mini)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                        .progressViewStyle(.linear)
                }
            }
        }
        .padding(.vertical, 3)
    }

    private var symbol: String {
        switch job.state {
        case .downloading: return "arrow.down.circle.fill"
        case .decrypting: return "lock.open.fill"
        case .verifying: return "checkmark.shield.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch job.state {
        case .completed: return .green
        case .failed: return .red
        default: return .teal
        }
    }
}

// MARK: - app list

struct AppList: View {
    var deviceOnly = false
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var filtered: [InstalledApp] {
        model.apps.filter { app in
            if model.filterDumpable && app.kind != .appStore { return false }
            guard !query.trimmed.isEmpty else { return true }
            let q = query.lowercased()
            return app.name.lowercased().contains(q) || app.bundleId.lowercased().contains(q)
        }
    }

    /// Re-run the store search only once typing settles. The phone list never
    /// refreshes by itself, so nothing jumps.
    private var storeKey: String {
        showsStoreList ? "\(query.trimmed)|\(model.storeRegion)" : ""
    }

    private var showsDeviceList: Bool {
        model.hasConnectedDevice && (deviceOnly || model.listMode == .device)
    }

    private var showsStoreList: Bool {
        !showsDeviceList
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsStoreList {
                regionPicker
            }
            if model.hasConnectedDevice && !deviceOnly {
                Picker("来源", selection: $model.listMode) {
                    ForEach(ListMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)
            }

            searchBar

            Divider()

            Group {
                if showsStoreList { StoreList() } else { deviceList }
            }
        }
        .task(id: storeKey) {
            guard showsStoreList, !storeKey.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            await model.runStoreSearch(query)
        }
        .onChange(of: model.listMode) { _, _ in
            // The two lists mean different things by the same word, so never let a
            // stale query drive the other one.
            query = ""
        }
        .toolbar {
            if !showsStoreList {
                ToolbarItem {
                    HStack(spacing: 6) {
                        if model.selectedAppIDs.count > 1 {
                            Button {
                                model.dumpMany(model.selectedDumpableApps)
                            } label: {
                                Label("砸壳选中 \(model.selectedAppIDs.count)",
                                      systemImage: "hammer.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.selectedDevice?.injectable != true)
                            Button("取消选择") { model.selectedAppIDs = [] }
                        }
                        Toggle(isOn: $model.filterDumpable) {
                            Label("只看带壳", systemImage: "lock.fill")
                        }.toggleStyle(.button)
                            .help("只显示 App Store 加密应用")
                    }
                }
            }
        }
    }

    private var regionBinding: Binding<String> {
        Binding(get: { model.storeRegion }, set: { model.selectStoreRegion($0) })
    }

    private var regionPicker: some View {
        HStack(spacing: 7) {
            Text("地区").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: regionBinding) {
                ForEach(StoreRegion.allCases) { region in
                    Text(region.title).tag(region.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// An explicit field: `.searchable(placement: .sidebar)` never rendered a
    /// visible box in this split view, which left no way to type a name at all.
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField(showsStoreList ? "搜索 App Store 软件名"
                                     : "搜索名称或 Bundle ID", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($searchFocused)
                .onSubmit {
                    if showsStoreList {
                        Task { await model.runStoreSearch(query) }
                    }
                }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary)
                .help("清空")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(Color.secondary.opacity(0.16)))
        .padding(.horizontal, 10).padding(.bottom, 8)
        .background(
            // Keeps Cmd-F working now that the system search field is gone.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        )
    }

    private var deviceList: some View {
        // A Set binding gives native multi-selection: Shift for a range, Cmd to add.
        List(selection: $model.selectedAppIDs) {
            ForEach(filtered) { app in
                AppRow(app: app).tag(app.bundleId)
            }
        }
        .overlay(alignment: .topTrailing) {
            // Anchored so loading never shifts the rows underneath.
            if model.busy {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("读取中").font(.caption).foregroundStyle(.secondary)
                }
                .padding(6).background(.regularMaterial, in: Capsule())
                .padding(8)
            }
        }
        .overlay {
            if filtered.isEmpty && !model.busy {
                ContentUnavailableView(
                    model.filterDumpable ? "没有 App Store 应用" : "没有应用",
                    systemImage: "app.dashed",
                    description: Text(model.filterDumpable
                        ? "这个列表只筛选 App Store 安装、带壳的应用。取消筛选可看全部。"
                        : "设备上看不到应用"))
            }
        }
    }
}

struct StoreList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: $model.selectedStoreID) {
            ForEach(model.storeResults) { item in
                StoreRow(item: item).tag(item.id)
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.storeBusy {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("搜索中").font(.caption).foregroundStyle(.secondary)
                }
                .padding(6).background(.regularMaterial, in: Capsule())
                .padding(8)
            }
        }
        .overlay {
            if model.storeResults.isEmpty && !model.storeBusy {
                ContentUnavailableView(
                    model.storeNote.isEmpty ? "搜索 App Store" : model.storeNote,
                    systemImage: "magnifyingglass",
                    description: Text("\(StoreRegion.title(model.storeRegion)) App Store"))
            }
        }
    }
}

struct StoreRow: View {
    let item: StoreItem
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 9) {
            icon.frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).fontWeight(.medium)
                Text(item.seller.isEmpty ? item.bundleId : item.seller)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                Text(item.version).font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    if let size = optionalSize { chip(size, tone: .mute) }
                    chip(model.installedMatch(item) != nil ? "已装" : "需下载",
                         tone: model.installedMatch(item) != nil ? .ok : .info)
                }
            }
        }
        .padding(.vertical, 3)
        .simultaneousGesture(TapGesture().onEnded {
            if case .storeJob = model.sidebarSel { model.sidebarSel = nil }
        })
        .contextMenu {
            Button("下载并砸壳", systemImage: "hammer.fill") { model.dumpFromStore(item) }
            Button("复制 Bundle ID") { model.copy(item.bundleId) }
            if let app = model.installedMatch(item), !app.path.isEmpty {
                Button("复制手机上路径") { model.copy(app.path) }
            }
        }
    }

    private var optionalSize: String? { item.sizeText.isEmpty ? nil : item.sizeText }

    @ViewBuilder private var icon: some View {
        if let data = model.storeArt[item.id], let img = NSImage(data: data) {
            Image(nsImage: img).resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.secondary.opacity(0.18))
                .overlay(Text(String(item.name.prefix(1)))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary))
        }
    }
}

struct AppRow: View {
    let app: InstalledApp
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 9) {
            icon.frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(app.name).lineLimit(1).fontWeight(.medium)
                    if app.running {
                        Image(systemName: "circle.fill").font(.system(size: 5))
                            .foregroundStyle(.green)
                    }
                }
                Text(app.bundleId).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).textCase(nil)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 3) {
                Text(app.shortVersion).font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary)
                if app.kind == .appStore {
                    Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 3)
        .simultaneousGesture(TapGesture().onEnded {
            if case .storeJob = model.sidebarSel { model.sidebarSel = nil }
        })
        .contextMenu {
            if app.kind == .appStore {
                Button("砸壳", systemImage: "hammer") { model.dump(app) }
            }
            Button("复制 Bundle ID") { model.copy(app.bundleId) }
            if !app.path.isEmpty { Button("复制路径") { model.copy(app.path) } }
        }
    }

    @ViewBuilder private var icon: some View {
        if let data = model.icons[app.bundleId], let img = NSImage(data: data) {
            Image(nsImage: img).resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.secondary.opacity(0.18))
                .overlay(Text(String(app.name.prefix(1))).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary))
        }
    }
}

// MARK: - detail

struct DetailPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var mac = AppModel.shared.macFairPlay

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let job = model.selectedStoreJob {
                    MacStoreJobDetailView(job: job)
                } else if let job = model.selectedJob {
                    JobDetailView(job: job)
                } else {
                    if let dev = model.selectedDevice { ReadinessCard(dev: dev) }
                    if showsStoreList, let item = model.selectedStoreItem {
                        StoreHeader(item: item)
                        StoreActionCard(item: item)
                        if let job = storeJob(item) { JobSummaryRow(job: job) }
                    } else if showsStoreList {
                        ContentUnavailableView(
                            "搜索一个软件", systemImage: "magnifyingglass",
                            description: Text("App Store · \(StoreRegion.title(model.storeRegion))"))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else if let app = model.selectedApp {
                        AppHeader(app: app)
                        ActionCard(app: app)
                        if let job = jobFor(app) { JobSummaryRow(job: job) }
                    } else if model.selectedAppIDs.count > 1 {
                        BatchCard()
                    } else {
                        ContentUnavailableView(
                            "选择左侧应用", systemImage: "hand.point.up.left",
                            description: Text(showsStoreList
                                ? "搜一个软件名，就能下载安装再砸壳"
                                : "点一个 App Store 应用即可查看能否砸壳"))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    }
                }
            }
            .padding(18)
        }
        .background(WorkshopPalette.background)
        .onChange(of: model.selectedStoreID) { _, _ in
            if case .storeJob = model.sidebarSel { model.sidebarSel = nil }
        }
        .onChange(of: model.selectedAppIDs) { _, _ in
            if case .storeJob = model.sidebarSel { model.sidebarSel = nil }
        }
    }

    private var showsStoreList: Bool {
        !model.hasConnectedDevice || model.listMode == .store
    }

    private func jobFor(_ app: InstalledApp) -> DumpJob? {
        model.jobs.first { $0.app.bundleId == app.bundleId }
    }

    private func storeJob(_ item: StoreItem) -> DumpJob? {
        model.jobs.first { $0.app.bundleId == item.bundleId && $0.origin == .store }
    }
}

struct StoreHeader: View {
    let item: StoreItem
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            icon.frame(width: 66, height: 66)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name).font(.title3.weight(.semibold)).lineLimit(2)
                Text(item.bundleId).font(.caption).monospaced()
                    .foregroundStyle(.secondary).textSelection(.enabled)
                HStack(spacing: 5) {
                    chip(item.version.isEmpty ? "?" : "v" + item.version, tone: .mute)
                    chip(item.price.isEmpty ? "免费" : item.price, tone: .mute)
                    if !item.sizeText.isEmpty { chip(item.sizeText, tone: .mute) }
                    if !item.genres.isEmpty { chip(item.genres.first ?? "", tone: .mute) }
                    if let installed = model.installedText(item) {
                        chip(installed, tone: .ok)
                    } else {
                        chip("手机未安装", tone: .info)
                    }
                }
            }
            Spacer()
        }
    }

    @ViewBuilder private var icon: some View {
        if let data = model.storeArt[item.id], let img = NSImage(data: data) {
            Image(nsImage: img).resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.secondary.opacity(0.18))
        }
    }
}

struct StoreActionCard: View {
    let item: StoreItem
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let existing = model.installedMatch(item) {
                Label("手机已装 \(existing.name) \(existing.shortVersion)，直接砸",
                      systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                Button { model.dump(existing) } label: {
                    Label("开始砸壳", systemImage: "hammer.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.selectedDevice?.injectable != true || !model.canStartMore)
            } else {
                Label("手机里还没装，会从 App Store 下载并装上", systemImage: "arrow.down.app")
                    .foregroundStyle(.orange)
                HStack(spacing: 9) {
                    Button { model.dumpFromStore(item) } label: {
                        Label("电脑下载并砸壳", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canStartMore || !model.storeAuth.loggedIn
                              || model.selectedDevice?.injectable != true)
                    Button { model.dumpFromStore(item, onDevice: true) } label: {
                        Label("让手机自己下载", systemImage: "iphone.gen3")
                    }
                    .disabled(model.selectedDevice?.injectable != true
                              || !model.canStartMore)
                }
                Text("电脑路线：读取已初始化的下载会话 → 拉取带壳包 → 安装并解密 → 清理残留")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.storeAuth.loggedIn {
                    Label("电脑下载会话未初始化。运行随包的“初始化下载会话.command”后回到应用即可。",
                          systemImage: "terminal")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()
            MacOfflineStoreAction(item: item, mac: model.macFairPlay)

            Toggle(isOn: Binding(get: { model.settings.storeAutoUninstall },
                                 set: { model.settings.storeAutoUninstall = $0
                                        model.settings.save() })) {
                Text("砸完后自动卸载手机上的这个 App")
            }
            .font(.callout)
            .help("只卸载由本工具从 App Store 装上去的 App，脱壳包留在电脑")

            if let b = model.selectedDevice?.blocker {
                Label("暂时不能砸：\(b)。先完成上面的修复步骤。", systemImage: "lock.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)))
    }
}

struct MacOfflineStoreAction: View {
    let item: StoreItem
    @ObservedObject var mac: MacFairPlayController
    @EnvironmentObject var model: AppModel

    private var regionalCredentialReady: Bool {
        mac.credential(region: model.storeRegion, accountID: model.storeAuth.accountID) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("最新版").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("v" + item.version).font(.system(size: 11))
                    .foregroundStyle(WorkshopPalette.muted)
            }
            .padding(13)
            .background(WorkshopPalette.soft, in: RoundedRectangle(cornerRadius: 9))
            if !item.isFree {
                Text("付费应用仅支持当前账号已购版本。")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }
            if mac.modelReady {
                Button {
                    model.downloadStoreForMacFairPlay(item)
                } label: {
                    HStack(spacing: 8) {
                        if let job = mac.activeStoreJob(bundleId: item.bundleId,
                            region: model.storeRegion, accountID: model.storeAuth.accountID) {
                            Text("\(job.state.rawValue) · \(progressPercent(job))")
                        } else {
                            Text("下载并砸壳")
                        }
                        Spacer()
                        Image(systemName: "arrow.down.to.line")
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(WorkshopPrimaryButton())
                .disabled(mac.activeStoreJob(bundleId: item.bundleId,
                    region: model.storeRegion, accountID: model.storeAuth.accountID) != nil
                          || !mac.canStartStoreJob)
            } else {
                Button {
                    mac.refresh()
                    model.presentSettings(.offline)
                } label: {
                    Text("配置账号凭据").frame(maxWidth: .infinity)
                }.buttonStyle(WorkshopPrimaryButton())
            }
            HStack {
                StoreHistoryButton(item: item)
                Spacer()
                Button("账号设置") { model.presentSettings(.offline) }
            }.font(.system(size: 11)).buttonStyle(.borderless)
            if !regionalCredentialReady || !model.storeAuth.loggedIn {
                Text(model.storeAuth.loggedIn ? "请先在设置中绑定当前地区的解密凭据。" : "当前地区尚未初始化下载会话，请在账号设置中配置。")
                    .font(.system(size: 10)).foregroundStyle(WorkshopPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func progressPercent(_ job: MacStoreJob) -> String {
        guard let fraction = job.progressFraction else { return "处理中" }
        return "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }
}

/// Shown when several apps are selected: one action for the whole batch.
struct BatchCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let picked = model.selectedApps
        let dumpable = model.selectedDumpableApps
        let bytes = picked.reduce(Int64(0)) { $0 + $1.sizeKB * 1024 }
        VStack(alignment: .leading, spacing: 11) {
            Label("已选中 \(picked.count) 个应用", systemImage: "square.stack.3d.up")
                .font(.headline)
            HStack(spacing: 5) {
                chip("\(dumpable.count) 个带壳", tone: .warn)
                if picked.count - dumpable.count > 0 {
                    chip("\(picked.count - dumpable.count) 个无壳", tone: .mute)
                }
                if bytes > 0 {
                    chip(String(format: "约 %.1f GB", Double(bytes) / 1_073_741_824), tone: .mute)
                }
                chip("并行 \(max(1, model.settings.maxParallel))", tone: .info)
            }
            Button {
                model.dumpMany(dumpable)
                model.selectedAppIDs = []
            } label: {
                Label("开始批量砸壳", systemImage: "hammer.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(dumpable.isEmpty || model.selectedDevice?.injectable != true)
            Text("带壳的会排队依次处理，跑满 \(max(1, model.settings.maxParallel)) 个并行；"
                     + "没有壳的自动跳过。产物按软件名-版本号-是否全解密命名，"
                     + "落在 \(model.settings.resolvedOutDir.path)")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                ForEach(picked.prefix(12)) { app in
                    HStack(spacing: 6) {
                        Image(systemName: app.dumpable ? "lock.fill" : "checkmark.seal")
                            .font(.caption2)
                            .foregroundStyle(app.dumpable ? Color.orange : Color.secondary)
                        Text(app.name).font(.callout).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(app.shortVersion).font(.caption2).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                if picked.count > 12 {
                    Text("还有 \(picked.count - 12) 个…").font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)))
    }
}

/// One line in the app view; the full log lives on its own task page.
struct JobSummaryRow: View {
    let job: DumpJob
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(job.app.name) · \(job.state.rawValue)").font(.callout.weight(.medium))
                Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if job.state == .running, let f = job.fraction {
                ProgressView(value: f).frame(width: 90).controlSize(.mini)
            }
            Button("查看日志") { model.sidebarSel = .job(job.id) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)))
    }

    private var detail: String {
        switch job.state {
        case .succeeded:
            guard let r = job.result else { return "已完成" }
            return String(format: "%.1f MB · %d 个二进制 · %.0fs", r.mb, r.binaries, r.seconds)
        case .failed: return job.log.last ?? "失败"
        default: return job.phaseNote.isEmpty ? job.stage : job.phaseNote
        }
    }
    private var symbol: String {
        switch job.state {
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .running: return "circle.dashed"
        case .queued: return "clock"
        }
    }
    private var color: Color {
        switch job.state {
        case .succeeded: return .green
        case .failed: return .red
        case .running: return .teal
        case .queued: return .secondary
        }
    }
}

struct ReadinessCard: View {
    let dev: IOSDevice
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "cable.connector")
                Text("\(dev.name) 就绪状态").fontWeight(.semibold)
                Spacer()
                Text(dev.shortUDID).font(.caption).monospaced().foregroundStyle(.secondary)
            }
            FlowChecklist(dev: dev, probed: model.env.py.ready)
            if !dev.injectable {
                HStack(spacing: 8) {
                    if dev.ddiRequired || !dev.enumerateOK {
                        FixButton(title: "挂载 Developer Image", icon: "arrow.down.circle",
                                  prominent: dev.ddiRequired, disabled: model.busy,
                                  action: { model.mountDDI() })
                    }
                    FixButton(title: "推送 frida-server 到手机", icon: "square.and.arrow.up",
                              prominent: dev.needsFridaServer,
                              disabled: model.busy || model.env.clientFridaVersion == nil,
                              action: { model.prepareFridaServer() })
                }
                if let b = dev.blocker {
                    Label(b, systemImage: "exclamationmark.arrow.trianglepath.dotted")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(dev.fridaError ?? "")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2).textCase(nil)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)))
    }
}

struct FlowChecklist: View {
    let dev: IOSDevice
    /// When the Mac has no frida-python yet, the probe never ran; saying "failed"
    /// would blame the phone for a host-side gap.
    let probed: Bool
    var body: some View {
        HStack(spacing: 12) {
            Check(label: "已连接", state: .yes)
            Check(label: "DDI", state: probed ? (dev.enumerateOK ? .yes : .no) : .na)
            Check(label: "frida-server", state: probed ? (dev.injectable ? .yes : .no) : .na)
        }
    }
}

enum CheckState { case yes, no, na }

struct Check: View {
    let label: String
    let state: CheckState
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var icon: String {
        switch state {
        case .yes: return "checkmark.circle.fill"
        case .no: return "xmark.circle.fill"
        case .na: return "questionmark.circle"
        }
    }
    private var color: Color {
        switch state {
        case .yes: return .green
        case .no: return .orange
        case .na: return .secondary
        }
    }
}

struct AppHeader: View {
    let app: InstalledApp
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon.frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.title3.weight(.semibold))
                Text(app.bundleId).font(.callout).monospaced().foregroundStyle(.secondary)
                HStack(spacing: 7) {
                    chip(app.kind.rawValue, tone: app.kind == .appStore ? .warn : .ok)
                    Text("v\(app.shortVersion) (\(app.buildVersion))")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    if !app.sizeText.isEmpty {
                        Label(app.sizeText, systemImage: "internaldrive")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                            .help("设备上 .app 实际占用")
                    } else if model.selectedDevice?.injectable == true {
                        Text("读取大小…").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
        }
    }

    @ViewBuilder private var icon: some View {
        if let data = model.icons[app.bundleId], let img = NSImage(data: data) {
            Image(nsImage: data.count > 0 ? img : NSImage())
                .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.secondary.opacity(0.18))
                .overlay(Text(String(app.name.prefix(1)))
                    .font(.system(size: 22, weight: .semibold)).foregroundStyle(.secondary))
        }
    }
}

struct ActionCard: View {
    let app: InstalledApp
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if app.kind == .appStore {
                Label("这个应用带 FairPlay 壳，可以砸", systemImage: "lock.open.fill")
                    .foregroundStyle(.orange)
                HStack(spacing: 9) {
                    Button { model.dump(app) } label: {
                        Label("开始砸壳", systemImage: "hammer.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selectedDevice?.injectable != true || !model.canStartMore)
                    if !app.path.isEmpty {
                        Button { model.copy(app.path) } label: {
                            Label("复制路径", systemImage: "doc.on.doc")
                        }
                    }
                }
                if let b = model.selectedDevice?.blocker {
                    Label("暂时不能砸：\(b)。先完成上面的修复步骤。",
                          systemImage: "lock.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label("不需要砸壳", systemImage: "checkmark.seal")
                Text(app.kind == .system
                     ? "系统应用没有 FairPlay 加密。"
                     : "非 App Store 签名（TrollStore / 自签），二进制本来就是明文。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !app.path.isEmpty {
                Divider()
                Text(app.path).font(.caption2).monospaced().foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)))
    }
}

struct FixButton: View {
    let title: String
    let icon: String
    let prominent: Bool
    let disabled: Bool
    let action: () -> Void
    var body: some View {
        Group {
            if prominent {
                Button(action: action) { Label(title, systemImage: icon) }
                    .buttonStyle(.borderedProminent)
            } else {
                Button(action: action) { Label(title, systemImage: icon) }
                    .buttonStyle(.bordered)
            }
        }
        .disabled(disabled)
    }
}

struct MacStoreJobDetailView: View {
    let job: MacStoreJob
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Button { model.sidebarSel = nil } label: {
                    Image(systemName: "chevron.left").frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("返回任务列表")
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.item.name).font(.title3.weight(.semibold))
                    Text("\(job.item.bundleId) · v\(job.item.version)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                chip(job.state.rawValue, tone: tone)
                Spacer()
                if let fraction = job.progressFraction, job.state.isActive {
                    Text("\(Int((min(max(fraction, 0), 1) * 100).rounded()))%")
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.teal)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(job.stage).font(.callout.weight(.medium))
                    Spacer()
                    if job.state.isActive {
                        ProgressView().controlSize(.small)
                    }
                }
                if job.state.isActive || job.state == .completed {
                    if let fraction = job.progressFraction {
                        ProgressView(value: min(max(fraction, 0), 1))
                            .progressViewStyle(.linear)
                    } else if job.state.isActive {
                        ProgressView()
                            .progressViewStyle(.linear)
                    }
                }
                Text(job.progressDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    chip(job.item.sizeText.isEmpty ? "大小未知" : job.item.sizeText, tone: .mute)
                    if job.encryptedImages > 0 {
                        chip("Mach-O \(job.encryptedImages)", tone: .info)
                    }
                    if job.decryptedPages > 0 {
                        chip("解密页 \(job.decryptedPages)", tone: .info)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.18)))

            if let output = job.outputURL {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 9) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([output])
                        } label: {
                            Label("在访达中显示", systemImage: "folder")
                        }
                        Button { model.copy(output.path) } label: {
                            Label("复制路径", systemImage: "doc.on.doc")
                        }
                        Spacer()
                        if let verified = job.verified {
                            chip(verified ? "全解密已校验" : "仍有加密镜像",
                                 tone: verified ? .ok : .warn)
                        }
                    }
                    Text(output.lastPathComponent)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.18)))
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("日志 (\(job.log.count) 行)").font(.callout.weight(.medium))
                    Spacer()
                    Button {
                        model.copy(job.log.joined(separator: "\n"))
                    } label: {
                        Label("复制全部", systemImage: "doc.on.doc")
                    }
                    .disabled(job.log.isEmpty)
                }
                ScrollView {
                    Text(job.log.isEmpty ? "（暂无输出）" : job.log.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(9)
                .frame(minHeight: 220, idealHeight: 340, maxHeight: 520,
                       alignment: .topLeading)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.18)))
            }
        }
    }

    private var tone: ChipTone {
        switch job.state {
        case .completed: return .ok
        case .failed: return .warn
        default: return .info
        }
    }
}

struct JobDetailView: View {
    let job: DumpJob
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Button { model.sidebarSel = nil } label: {
                    Image(systemName: "chevron.left").frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("返回任务列表")
                Text(job.app.name).font(.title3.weight(.semibold))
                chip(job.state.rawValue, tone: tone)
                Spacer()
                if let r = job.result {
                    Text(String(format: "%.1f MB · %d 个二进制 · %.0fs", r.mb, r.binaries, r.seconds))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }

            if job.state == .running {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(job.stage).font(.callout)
                        Spacer()
                        if let f = job.fraction {
                            Text("\(Int(f * 100))%").font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    ProgressView(value: job.fraction ?? 0).progressViewStyle(.linear)
                    if !job.phaseNote.isEmpty {
                        Text(job.phaseNote).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if let r = job.result, job.state == .succeeded {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 9) {
                        Button { model.reveal(r.ipa) } label: {
                            Label("在访达中显示", systemImage: "folder")
                        }
                        Button { model.copy(r.ipa.path) } label: {
                            Label("复制路径", systemImage: "doc.on.doc")
                        }
                    }
                    Label(r.ipa.lastPathComponent, systemImage: "doc.zipper")
                        .font(.caption).monospaced().textSelection(.enabled)
                    if !job.verifyNote.isEmpty {
                        Label(job.verifyNote, systemImage: job.verifyNote.hasPrefix("已验证")
                              ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                            .foregroundStyle(job.verifyNote.hasPrefix("已验证") ? .green : .orange)
                    }
                    if !r.stillEncrypted.isEmpty {
                        Label("仍有 \(r.stillEncrypted.count) 个二进制带壳：\(r.stillEncrypted.joined(separator: ", "))",
                              systemImage: "lock.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            // Log is open by default and selectable as one block.
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text("日志 (\(job.log.count) 行)").font(.callout.weight(.medium))
                    Spacer()
                    Button {
                        model.copy(job.log.joined(separator: "\n"))
                    } label: {
                        Label("复制全部", systemImage: "doc.on.doc")
                    }
                    .disabled(job.log.isEmpty)
                }
                ScrollView {
                    Text(job.log.isEmpty ? "（暂无输出）" : job.log.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(9)
                .frame(maxWidth: .infinity, maxHeight: 420, alignment: .topLeading)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.18)))
            }
        }
    }

    private var tone: ChipTone {
        switch job.state {
        case .succeeded: return .ok
        case .failed: return .warn
        case .running: return .info
        case .queued: return .mute
        }
    }
}

struct StatusBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if let n = model.notice {
                Image(systemName: "info.circle").foregroundStyle(.teal)
                Text(n).lineLimit(1)
            } else {
                Image(systemName: "cpu").foregroundStyle(.secondary)
                Text(model.catalogNote.isEmpty ? "就绪" : model.catalogNote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.runningCount > 0 || model.hasWaitingWork {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.caption2)
                    Text("\(model.runningCount)/\(max(1, model.settings.maxParallel)) 并行"
                         + (model.hasWaitingWork ? " · 排队 \(model.queuedJobs.count)" : ""))
                        .monospacedDigit()
                }
                .font(.caption).foregroundStyle(.teal)
                Divider().frame(height: 12)
            }
            Text("frida \(model.env.clientFridaVersion ?? "未装")")
                .font(.caption).monospaced().foregroundStyle(.secondary)
            if let t = model.lastRefresh {
                Text("刷新 \(t, format: .dateTime.hour().minute().second())")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }
}
