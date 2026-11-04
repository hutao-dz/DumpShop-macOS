import AppKit
import SwiftUI

enum WorkshopPalette {
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
    }
    static let background = adaptive(0xf7f9f8, 0x131d1b)
    static let surface = adaptive(0xffffff, 0x1b2925)
    static let ink = adaptive(0x152d2a, 0xe2ede7)
    static let muted = adaptive(0x7b8986, 0x9bb0a6)
    static let accent = adaptive(0x117b6c, 0x78c9ad)
    static let soft = adaptive(0xedf6f2, 0x253c33)
    static let line = adaptive(0xe6ece9, 0x304239)
}

struct WorkshopCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(WorkshopPalette.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(WorkshopPalette.line, lineWidth: 1))
    }
}

struct WorkshopPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 18).padding(.vertical, 12)
            .foregroundStyle(Color.white)
            .background(Color(red: 0.067, green: 0.482, blue: 0.424)
                .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4),
                        in: RoundedRectangle(cornerRadius: 9))
    }
}

struct WorkshopEyebrow: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 9, weight: .semibold))
            .tracking(1.8).foregroundStyle(WorkshopPalette.muted)
    }
}

struct WorkshopBrandIcon: View {
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
               let icon = NSImage(contentsOf: url) {
                Image(nsImage: icon).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.dashed").resizable().scaledToFit()
                    .padding(7).foregroundStyle(WorkshopPalette.accent)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
    }
}

private enum WorkshopPage { case explore, jobs, device }

struct WorkshopView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var mac = AppModel.shared.macFairPlay
    @State private var page: WorkshopPage = .explore
    @State private var searchQuery = ""

    private var deviceAvailable: Bool { model.devices.contains { $0.injectable } }
    private var taskCount: Int { model.jobs.count + mac.storeJobs.count }
    private var activeCount: Int {
        model.jobs.filter { $0.state == .running || $0.state == .queued }.count + mac.activeStoreCount
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(WorkshopPalette.line).frame(height: 1)
            Group {
                switch page {
                case .explore:
                    WorkshopExplore(showTasks: { page = .jobs }, query: $searchQuery)
                case .jobs:
                    WorkshopJobs()
                case .device:
                    VStack(spacing: 0) {
                        HStack {
                            Picker("已连接设备", selection: $model.selectedUDID) {
                                ForEach(model.devices.filter { $0.injectable }) { device in
                                    Text(device.name).tag(Optional(device.udid))
                                }
                            }.frame(maxWidth: 330)
                            Spacer()
                            Button { model.refresh() } label: {
                                Label("刷新设备与应用", systemImage: "arrow.clockwise")
                            }.disabled(model.busy)
                        }.padding(.horizontal, 32).padding(.vertical, 12)
                        Divider()
                        HStack(spacing: 0) {
                            AppList(deviceOnly: true).frame(minWidth: 350, idealWidth: 430, maxWidth: 500)
                            Divider()
                            DetailPanel()
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(WorkshopPalette.line).frame(height: 1)
            footer
        }
        .background(WorkshopPalette.background)
        .foregroundStyle(WorkshopPalette.ink)
        .tint(WorkshopPalette.accent)
        .onAppear { model.listMode = .store }
        .onChange(of: model.selectedUDID) { _, _ in
            if page == .device { model.refresh() }
        }
        .onChange(of: model.sidebarSel) { _, selection in
            if page == .device, model.selectedJob != nil || model.selectedStoreJob != nil {
                page = .jobs
            }
        }
        .onChange(of: deviceAvailable) { _, available in
            if !available && page == .device { navigate(.explore) }
        }
    }

    private var header: some View {
        HStack(spacing: 32) {
            Button { navigate(.explore) } label: {
                HStack(spacing: 11) {
                    WorkshopBrandIcon().frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("砸壳工坊").font(.system(size: 18, weight: .bold))
                        Text("YOUR APP, YOUR VERSION")
                            .font(.system(size: 8, weight: .medium)).tracking(1.3)
                            .foregroundStyle(WorkshopPalette.muted)
                    }
                }
            }.buttonStyle(.plain)
            HStack(spacing: 27) {
                navigation("应用探索", destination: .explore)
                navigation("我的砸壳", destination: .jobs, count: taskCount)
                if deviceAvailable { navigation("手机已装", destination: .device) }
            }
            .padding(.leading, 16)
            Spacer(minLength: 12)
            if activeCount > 0 {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("\(activeCount) 个任务进行中").font(.system(size: 11))
                }.foregroundStyle(WorkshopPalette.muted)
            }
            Button { openSettings() } label: {
                Label("设置", systemImage: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 13).frame(height: 36)
                    .background(WorkshopPalette.soft, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(WorkshopPalette.line))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("设置").accessibilityLabel("设置")
        }
        .padding(.horizontal, 32).padding(.vertical, 16)
        .background(WorkshopPalette.surface)
    }

    private func navigation(_ title: String, destination: WorkshopPage, count: Int = 0) -> some View {
        Button { navigate(destination) } label: {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12, weight: page == destination ? .semibold : .medium))
                if count > 0 {
                    Text("\(count)").font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(WorkshopPalette.soft, in: Capsule())
                }
            }
            .foregroundStyle(page == destination ? WorkshopPalette.accent : WorkshopPalette.muted)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if page == destination {
                    Capsule().fill(WorkshopPalette.accent).frame(width: 20, height: 3).offset(y: 16)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if let notice = model.notice {
                Text(notice).lineLimit(1).help(notice).textSelection(.enabled)
                Button { model.notice = nil } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain).accessibilityLabel("关闭提示")
            } else {
                Text("每个版本，都值得保留。")
            }
            Spacer()
            Text("\(taskCount) 个任务")
            if let device = model.selectedDevice {
                Text(device.name).lineLimit(1)
            }
            Button {
                let output = model.settings.resolvedOutDir
                try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                NSWorkspace.shared.open(output)
            } label: {
                Label("输出文件夹", systemImage: "folder")
            }.buttonStyle(.plain)
        }
        .font(.system(size: 10)).foregroundStyle(WorkshopPalette.muted)
        .padding(.horizontal, 32).padding(.vertical, 12)
        .background(WorkshopPalette.surface)
    }

    private func navigate(_ destination: WorkshopPage) {
        model.sidebarSel = nil
        page = destination
        model.listMode = destination == .device ? .device : .store
        if destination == .device,
           !model.devices.contains(where: { $0.udid == model.selectedUDID && $0.injectable }) {
            model.selectedUDID = model.devices.first(where: { $0.injectable })?.udid
        }
    }
}

struct WorkshopRegionButton: View {
    let region: StoreRegion
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(region.title).font(.system(size: 12, weight: .semibold))
                Text(region.rawValue).font(.system(size: 9, weight: .medium)).tracking(0.5)
                    .opacity(selected ? 0.75 : 0.6)
            }
            .foregroundStyle(selected ? Color.white : WorkshopPalette.ink)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(selected ? Color(red: 0.067, green: 0.482, blue: 0.424)
                        : hovering ? WorkshopPalette.soft : WorkshopPalette.background,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.clear : hovering ? WorkshopPalette.accent.opacity(0.3)
                        : WorkshopPalette.line, lineWidth: 1))
            // Include all empty space around the label in the button's hit area.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("切换至\(region.title)")
        .accessibilityValue(selected ? "已选中" : "未选中")
        .help("切换到\(region.title) App Store")
    }
}

private struct WorkshopExplore: View {
    @EnvironmentObject private var model: AppModel
    let showTasks: () -> Void
    @Binding var query: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if model.storeResults.isEmpty {
                        WorkshopHero()
                        libraryHeader
                    } else {
                        VStack(alignment: .leading, spacing: 9) {
                            WorkshopEyebrow(text: "EXPLORE THE LIBRARY")
                            Text("好应用，选好你的版本。")
                                .font(.system(size: 23, weight: .semibold))
                        }.padding(.top, 6)
                    }
                    searchPanel
                    results
                    if model.storeResults.isEmpty && !model.storeBusy { suggestions }
                }
                .padding(32)
                .frame(maxWidth: 1280)
                .frame(maxWidth: .infinity)
            }
            if let item = model.selectedStoreItem {
                Rectangle().fill(WorkshopPalette.line).frame(width: 1)
                WorkshopInspector(item: item, showTasks: showTasks)
                    .frame(width: 350)
                    .id("\(model.storeRegion)-\(item.id)")
            }
        }
        .task(id: "\(query.trimmed)|\(model.storeRegion)") {
            guard !query.trimmed.isEmpty else {
                model.storeSearchGeneration = UUID()
                model.storeResults = []
                model.selectedStoreID = nil
                model.storeBusy = false
                model.storeNote = ""
                return
            }
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            await model.runStoreSearch(query)
        }
        .defaultFocus($focused, false, priority: .userInitiated)
        .background {
            Button("") { focused = true }.keyboardShortcut("f", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
    }

    private var libraryHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 7) {
                WorkshopEyebrow(text: "EXPLORE THE LIBRARY")
                Text("发现下一个好应用").font(.system(size: 23, weight: .semibold))
            }
            Spacer()
            Text("\(StoreRegion.title(model.storeRegion)) App Store")
                .font(.system(size: 10)).foregroundStyle(WorkshopPalette.muted)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .overlay(Capsule().stroke(WorkshopPalette.line))
        }
    }

    private var searchPanel: some View {
        VStack(spacing: 15) {
            HStack(spacing: 8) {
                ForEach([StoreRegion.cn, .hk, .us, .jp, .tw]) { region in
                    WorkshopRegionButton(region: region, selected: model.storeRegion == region.rawValue) {
                        model.selectStoreRegion(region.rawValue)
                    }
                }
            }
            Rectangle().fill(WorkshopPalette.line).frame(height: 1)
            HStack(spacing: 11) {
                Image(systemName: "magnifyingglass").foregroundStyle(WorkshopPalette.muted)
                TextField("搜索应用名称，如微信、Notion…", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 12)).focused($focused)
                    .onSubmit { search() }
                    .accessibilityLabel("应用名称")
                if !query.isEmpty {
                    Button {
                        query = ""
                        model.storeSearchGeneration = UUID()
                        model.storeResults = []
                        model.selectedStoreID = nil
                        model.storeBusy = false
                        model.storeNote = ""
                    } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(WorkshopPalette.muted)
                        .accessibilityLabel("清空搜索")
                }
                Button("搜索应用") { search() }
                    .buttonStyle(WorkshopPrimaryButton()).disabled(query.trimmed.isEmpty)
            }
        }
        .padding(18).modifier(WorkshopCard())
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(query.trimmed.isEmpty ? "从喜欢的应用开始" : "搜索结果")
                Spacer()
                if model.storeBusy {
                    ProgressView().controlSize(.small)
                    Text("搜索中…")
                } else if !model.storeResults.isEmpty {
                    Text("\(model.storeResults.count) 个应用")
                }
            }.font(.system(size: 11)).foregroundStyle(WorkshopPalette.muted)
            if model.storeResults.isEmpty && !model.storeBusy && !query.trimmed.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.system(size: 24))
                    Text(model.storeNote.isEmpty ? "输入应用名称，探索更多版本" : model.storeNote)
                        .font(.system(size: 12)).multilineTextAlignment(.center)
                }
                .foregroundStyle(WorkshopPalette.muted)
                .frame(maxWidth: .infinity).padding(.vertical, 35)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: 17)], spacing: 17) {
                ForEach(model.storeResults) { item in
                    WorkshopAppCard(item: item, selected: model.selectedStoreID == item.id) {
                        model.sidebarSel = nil
                        model.selectedStoreID = item.id
                    }
                }
            }
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(spacing: 10) {
                Text("试试搜索").font(.system(size: 11)).foregroundStyle(WorkshopPalette.muted)
                ForEach(["微信", "抖音", "小红书", "Notion"], id: \.self) { term in
                    Button { query = term } label: {
                        Text(term).font(.system(size: 11)).padding(.horizontal, 13).padding(.vertical, 8)
                            .background(WorkshopPalette.surface, in: Capsule())
                            .overlay(Capsule().stroke(WorkshopPalette.line))
                    }.buttonStyle(.plain)
                }
            }
            Rectangle().fill(WorkshopPalette.line).frame(height: 1)
            HStack(alignment: .top, spacing: 25) {
                step("01", "选好商店地区", "五个地区，发现不同的应用。")
                step("02", "选择想要的版本", "最新版，或你熟悉的历史版本。")
                step("03", "完成后留在本地", "任务进度与日志，随时可查看。")
            }
        }
    }

    private func step(_ number: String, _ title: String, _ subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Text(number).font(.system(size: 24, weight: .light))
                .foregroundStyle(WorkshopPalette.accent.opacity(0.35))
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.system(size: 11, weight: .medium))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(WorkshopPalette.muted)
            }.padding(.top, 4)
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func search() {
        guard !query.trimmed.isEmpty else { return }
        Task { await model.runStoreSearch(query) }
    }
}

private struct WorkshopHero: View {
    var compact = false
    var body: some View {
        HStack(spacing: 30) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 9) {
                    Rectangle().fill(WorkshopPalette.accent).frame(width: 19, height: 1)
                    WorkshopEyebrow(text: "A LITTLE MORE POSSIBILITY")
                }
                (Text("好应用，\n也值得有更多") + Text("版本选择。").foregroundColor(WorkshopPalette.accent))
                    .font(.system(size: compact ? 29 : 36, weight: .bold))
                    .tracking(-1.4).lineSpacing(8).fixedSize(horizontal: false, vertical: true)
                Text("从五区商店找到应用，选择需要的版本。\n剩下的交给工坊，完成后保存在本地。")
                    .font(.system(size: 12)).foregroundStyle(WorkshopPalette.muted).lineSpacing(6)
                HStack(spacing: 13) {
                    Text("5 个商店地区")
                    Text("·").opacity(0.4)
                    Text("自由选择版本")
                    Text("·").opacity(0.4)
                    Text("在 Mac 上完成")
                }.font(.system(size: 10)).foregroundStyle(WorkshopPalette.muted)
                    .padding(.top, 4)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if !compact { WorkshopVersionArtwork().frame(width: 350, height: 225) }
        }
        .padding(.vertical, compact ? 12 : 24)
    }
}

private struct WorkshopVersionArtwork: View {
    private let colors: [Color] = [Color(red: 0.41, green: 0.62, blue: 0.49),
        Color(red: 0.85, green: 0.66, blue: 0.44), Color(red: 0.72, green: 0.58, blue: 0.61),
        Color(red: 0.53, green: 0.59, blue: 0.73)]
    private let symbols = ["square.grid.3x3.fill", "sparkle", "music.note", "a.square.fill"]
    var body: some View {
        ZStack {
            Ellipse().stroke(WorkshopPalette.line).frame(width: 335, height: 195).rotationEffect(.degrees(-20))
            Ellipse().stroke(WorkshopPalette.line).frame(width: 305, height: 220).rotationEffect(.degrees(25))
            RoundedRectangle(cornerRadius: 16).fill(WorkshopPalette.soft)
                .frame(width: 280, height: 176).rotationEffect(.degrees(-11))
            RoundedRectangle(cornerRadius: 16).fill(WorkshopPalette.soft)
                .frame(width: 280, height: 176).rotationEffect(.degrees(5))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(WorkshopPalette.line)
                    .frame(width: 280, height: 176).rotationEffect(.degrees(5)))
            VStack(spacing: 20) {
                HStack(spacing: 9) {
                    WorkshopBrandIcon().frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("YOUR NEXT DOWNLOAD").font(.system(size: 7, weight: .medium)).tracking(1)
                        Text("准备好喜欢的版本").font(.system(size: 9))
                    }.foregroundStyle(WorkshopPalette.muted)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(WorkshopPalette.accent)
                }
                HStack(spacing: 13) {
                    ForEach(0..<4) { index in
                        Image(systemName: symbols[index]).font(.system(size: 24))
                            .foregroundStyle(.white).frame(width: 44, height: 44)
                            .background(colors[index], in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                VStack(spacing: 8) {
                    Capsule().fill(WorkshopPalette.accent.opacity(0.45)).frame(height: 3)
                    HStack {
                        Text("每个版本，都有可能")
                        Spacer()
                        Text("100%")
                    }.font(.system(size: 8)).foregroundStyle(WorkshopPalette.muted)
                }
            }
            .padding(20).frame(width: 280).modifier(WorkshopCard())
            .shadow(color: WorkshopPalette.accent.opacity(0.06), radius: 16, y: 10)
            .rotationEffect(.degrees(-3))
        }.accessibilityHidden(true)
    }
}

struct WorkshopArtwork: View {
    let item: StoreItem
    @EnvironmentObject private var model: AppModel
    var body: some View {
        Group {
            if let data = model.storeArt[item.id], let image = NSImage(data: data) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 12).fill(WorkshopPalette.soft)
                    .overlay(Text(String(item.name.prefix(1))).font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(WorkshopPalette.accent))
            }
        }.clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct WorkshopAppCard: View {
    let item: StoreItem
    let selected: Bool
    let select: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    WorkshopArtwork(item: item).frame(width: 52, height: 52)
                    Spacer()
                    Text(item.genres.first ?? "应用").font(.system(size: 9))
                        .foregroundStyle(WorkshopPalette.muted).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(WorkshopPalette.line))
                }.padding(.bottom, 16)
                Text(item.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(item.seller.isEmpty ? item.bundleId : item.seller)
                    .font(.system(size: 10)).foregroundStyle(WorkshopPalette.muted)
                    .lineLimit(1).padding(.top, 6)
                HStack(spacing: 8) {
                    Text("v\(item.version)")
                    if !item.sizeText.isEmpty { Text("·"); Text(item.sizeText) }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10)).foregroundStyle(WorkshopPalette.muted).lineLimit(1)
                .padding(.vertical, 17)
                Rectangle().fill(WorkshopPalette.line).frame(height: 1)
                HStack {
                    Text(selected ? "正在查看" : "选择版本")
                    Spacer()
                    Text(item.price.isEmpty ? (item.isFree ? "免费" : "查看") : item.price)
                        .fontWeight(.regular).foregroundStyle(WorkshopPalette.muted)
                    Image(systemName: "arrow.up.right").font(.system(size: 11))
                }.font(.system(size: 11, weight: .medium))
                    .foregroundStyle(WorkshopPalette.accent).padding(.top, 13)
            }
            .padding(20).modifier(WorkshopCard())
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(
                WorkshopPalette.accent.opacity(selected ? 0.65 : hovering ? 0.2 : 0), lineWidth: 1))
            .shadow(color: WorkshopPalette.accent.opacity(hovering ? 0.07 : 0), radius: 10, y: 5)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .accessibilityLabel("\(item.name)，版本 \(item.version)，选择版本")
    }
}

private struct WorkshopInspector: View {
    let item: StoreItem
    let showTasks: () -> Void
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var mac = AppModel.shared.macFairPlay
    @State private var showDeviceActions = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                HStack {
                    WorkshopEyebrow(text: "MAKE IT YOUR VERSION")
                    Spacer()
                    Button { model.selectedStoreID = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 12))
                    }.buttonStyle(.plain).foregroundStyle(WorkshopPalette.muted)
                        .accessibilityLabel("关闭应用详情")
                }
                WorkshopArtwork(item: item).frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 9) {
                    Text(item.name).font(.system(size: 23, weight: .semibold))
                    Text(item.seller).font(.system(size: 11)).foregroundStyle(WorkshopPalette.muted)
                    Text(item.bundleId).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(WorkshopPalette.muted).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 0) {
                    metric("最新版本", item.version)
                    Divider().frame(height: 28)
                    metric("应用大小", item.sizeText.isEmpty ? "未知" : item.sizeText)
                    Divider().frame(height: 28)
                    metric("商店地区", StoreRegion.title(model.storeRegion))
                }
                Rectangle().fill(WorkshopPalette.line).frame(height: 1)
                VStack(alignment: .leading, spacing: 13) {
                    Text("选择你的版本").font(.system(size: 16, weight: .semibold))
                    Text("下载最新版，或查找熟悉的历史版本。")
                        .font(.system(size: 11)).foregroundStyle(WorkshopPalette.muted)
                    MacOfflineStoreAction(item: item, mac: mac)
                        .controlSize(.regular)
                }
                if let job = mac.storeJobs.first(where: { $0.item.id == item.id && $0.region == model.storeRegion }) {
                    Button {
                        model.sidebarSel = .storeJob(job.id)
                        showTasks()
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(job.state.isActive ? "任务正在进行" : "查看本次任务")
                                Spacer()
                                Image(systemName: "arrow.up.right")
                            }.font(.system(size: 11, weight: .medium))
                            if job.state.isActive { ProgressView(value: job.progressFraction ?? 0) }
                            Text(job.stage).font(.system(size: 10)).lineLimit(2)
                        }.padding(14).background(WorkshopPalette.soft, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).foregroundStyle(WorkshopPalette.accent)
                }
                if model.devices.contains(where: { $0.injectable }) {
                    DisclosureGroup("通过已连接的 iPhone 处理", isExpanded: $showDeviceActions) {
                        StoreActionCard(item: item).padding(.top, 10)
                    }.font(.system(size: 11))
                }
                Spacer(minLength: 12)
                Text("付费应用仅使用当前账号已有授权。\n完成的文件会保存在 Mac 输出文件夹中。")
                    .font(.system(size: 10)).foregroundStyle(WorkshopPalette.muted).lineSpacing(5)
            }.padding(26)
        }
        .background(WorkshopPalette.surface)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 9)).foregroundStyle(WorkshopPalette.muted)
            Text(value).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WorkshopJobs: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var mac = AppModel.shared.macFairPlay
    private var completed: Int {
        mac.storeJobs.filter { $0.state == .completed }.count + model.jobs.filter { $0.state == .succeeded }.count
    }
    private var active: Int {
        mac.activeStoreCount + model.jobs.filter { $0.state == .queued || $0.state == .running }.count
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                if model.selectedStoreJob != nil || model.selectedJob != nil {
                    WorkshopEyebrow(text: "TASK DETAILS")
                    if let job = model.selectedStoreJob { MacStoreJobDetailView(job: job) }
                    else if let job = model.selectedJob { JobDetailView(job: job) }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        WorkshopEyebrow(text: "MY WORKSPACE")
                        Text("我的砸壳").font(.system(size: 30, weight: .semibold))
                        Text("每一个任务，都有清晰的进度。点击任务查看详情和完整日志。")
                            .font(.system(size: 12)).foregroundStyle(WorkshopPalette.muted)
                    }.padding(.top, 14)
                    HStack(spacing: 15) {
                        stat("全部任务", mac.storeJobs.count + model.jobs.count)
                        stat("正在进行", active)
                        stat("已完成", completed)
                    }
                    if mac.storeJobs.isEmpty && model.jobs.isEmpty {
                        VStack(spacing: 15) {
                            Image(systemName: "tray").font(.system(size: 29, weight: .light))
                                .foregroundStyle(WorkshopPalette.accent.opacity(0.6))
                            Text("还没有任务").font(.system(size: 17, weight: .medium))
                            Text("在「应用探索」里找到喜欢的应用，选择版本即可开始。")
                                .font(.system(size: 12)).foregroundStyle(WorkshopPalette.muted)
                        }.frame(maxWidth: .infinity).padding(.vertical, 70).modifier(WorkshopCard())
                    }
                    ForEach(mac.storeJobs) { job in
                        WorkshopTaskCard(name: job.item.name,
                            subtitle: "\(StoreRegion.title(job.region)) · v\(job.requestedVersion?.displayVersion ?? job.item.version)",
                            state: job.state.rawValue, detail: job.stage,
                            fraction: job.progressFraction, active: job.state.isActive,
                            failed: job.state == .failed, item: job.item) {
                                model.sidebarSel = .storeJob(job.id)
                            }
                            .contextMenu {
                                Button("复制全部日志") { model.copy(job.log.joined(separator: "\n")) }
                                if let file = job.outputURL {
                                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                                }
                            }
                    }
                    ForEach(model.jobs) { job in
                        WorkshopTaskCard(name: job.app.name, subtitle: "iPhone · v\(job.app.shortVersion)",
                            state: job.state.rawValue, detail: job.stage, fraction: job.fraction,
                            active: job.state == .running || job.state == .queued,
                            failed: job.state == .failed, item: nil) {
                                model.sidebarSel = .job(job.id)
                            }
                            .contextMenu {
                                Button("复制全部日志") { model.copy(job.log.joined(separator: "\n")) }
                                if let file = job.result?.ipa {
                                    Button("在访达中显示") { model.reveal(file) }
                                }
                            }
                    }
                }
            }
            .frame(maxWidth: 1120, alignment: .leading).padding(32)
            .frame(maxWidth: .infinity)
        }
    }

    private func stat(_ title: String, _ count: Int) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(WorkshopPalette.muted)
            Spacer()
            Text("\(count)").font(.system(size: 25, weight: .medium)).monospacedDigit()
        }.padding(22).frame(maxWidth: .infinity).modifier(WorkshopCard())
    }
}

private struct WorkshopTaskCard: View {
    let name: String
    let subtitle: String
    let state: String
    let detail: String
    let fraction: Double?
    let active: Bool
    let failed: Bool
    let item: StoreItem?
    let select: () -> Void
    var body: some View {
        Button(action: select) {
            HStack(spacing: 21) {
                if let item { WorkshopArtwork(item: item).frame(width: 50, height: 50) }
                else {
                    Image(systemName: "app").font(.system(size: 24)).foregroundStyle(WorkshopPalette.accent)
                        .frame(width: 50, height: 50).background(WorkshopPalette.soft, in: RoundedRectangle(cornerRadius: 12))
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(WorkshopPalette.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(state).font(.system(size: 11, weight: .medium))
                        Spacer()
                        if let fraction, active {
                            Text("\(Int((min(max(fraction, 0), 1) * 100).rounded()))%")
                                .font(.system(size: 11)).monospacedDigit()
                        }
                    }.foregroundStyle(failed ? .red : WorkshopPalette.accent)
                    if active { ProgressView(value: fraction ?? 0).progressViewStyle(.linear) }
                    Text(detail).font(.system(size: 10)).foregroundStyle(WorkshopPalette.muted).lineLimit(1)
                }.frame(width: 260)
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(WorkshopPalette.muted)
            }.padding(23).modifier(WorkshopCard()).contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).accessibilityLabel("查看\(name)任务详情")
    }
}
