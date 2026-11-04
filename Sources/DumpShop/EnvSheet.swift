import AppKit
import SwiftUI

struct EnvironmentSettingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var s = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                    Form {
                        LabeledContent("Python") {
                            TextField("自动检测", text: $s.pythonOverride)
                            Button("自动") { s.pythonOverride = "" }
                        }
                        LabeledContent("脚本目录") {
                            TextField("内置脚本", text: $s.engineSource)
                            Button("自动") { s.engineSource = "" }
                        }
                        Button("应用并重新检测") {
                            s.save()
                            model.env.reprobe()
                            model.refresh()
                        }
                    }
                    ToolsCard()
                    PythonCard()
                    ChannelCard()
                    TipsCard()
            }
            .padding(20)
        }
        .onDisappear { s.save() }
    }
}

private struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.18)))
    }
}

private struct Row: View {
    let label: String
    let value: String
    let ok: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
            Text(label)
            Spacer()
            Text(value).font(.callout).monospaced().foregroundStyle(.secondary)
                .lineLimit(1).textCase(nil)
        }
    }
}

struct ToolsCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Card(title: "本机命令行工具", icon: "terminal") {
            if model.env.brewMissing.isEmpty {
                Row(label: "libimobiledevice 全套 + zip", value: "已安装", ok: true)
            } else {
                Row(label: "缺少", value: model.env.brewMissing.joined(separator: ", "), ok: false)
                HStack(spacing: 8) {
                    let cmd = "brew install libimobiledevice ideviceinstaller usbmuxd zip"
                    Button { model.copy(cmd) } label: {
                        Label("复制安装命令", systemImage: "doc.on.doc")
                    }
                    Text(cmd).font(.caption).monospaced().foregroundStyle(.secondary)
                        .lineLimit(1).textCase(nil)
                }
            }
        }
    }
}

struct PythonCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Card(title: "Python / frida", icon: "chevron.left.forwardslash.chevron.right") {
            Row(label: "解释器", value: model.env.py.path ?? "未找到",
                ok: model.env.py.path != nil)
            Row(label: "frida", value: model.env.py.fridaVersion ?? "未安装",
                ok: model.env.py.fridaVersion != nil)
            Row(label: "pymobiledevice3", value: model.env.py.pymobiledevice3 ? "已安装" : "未安装",
                ok: model.env.py.pymobiledevice3)
            HStack(spacing: 8) {
                Button { model.env.createVenv() } label: {
                    Label(model.env.py.installing ? "安装中…" : "创建独立环境",
                          systemImage: "plus.circle")
                }
                .disabled(model.env.py.installing)
                Button("重新检测") { model.env.reprobe() }
            }
            LabeledContent("pip 源") {
                Picker("", selection: Binding(
                    get: { model.settings.pipIndexURL.isEmpty ? "官方" : model.settings.pipIndexURL },
                    set: { model.settings.pipIndexURL = $0 == "官方" ? "" : $0
                           model.settings.save() })) {
                    Text("官方").tag("官方")
                    Text("阿里云").tag("https://mirrors.aliyun.com/pypi/simple/")
                    Text("清华 TUNA").tag("https://pypi.tuna.tsinghua.edu.cn/simple")
                }
                .labelsHidden().frame(width: 200)
            }
            Text("砸壳依赖 frida-python。应用会在 ~/Library/Application Support/DumpShop/venv 建一个独立环境，也可以直接复用已有的。")
                .font(.caption).foregroundStyle(.secondary)
            Text("PyPI 的文件主机在国内常被限到几十 KB/s，装环境像卡死。换上面的镜像源即可，pip 仍会按哈希校验每个包。")
                .font(.caption).foregroundStyle(.secondary)
            if !model.env.py.installLog.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(model.env.py.installLog.suffix(40), id: \.self) { l in
                            Text(l).font(.system(.caption2, design: .monospaced))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
                .padding(7)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}

struct ChannelCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Card(title: "设备注入通道", icon: "lock.badge.key") {
            if let dev = model.selectedDevice {
                Row(label: "设备", value: "\(dev.name) · iOS \(dev.version)", ok: true)
                Row(label: "Developer Image", value: dev.enumerateOK ? "已挂载" : "未挂载",
                    ok: dev.enumerateOK)
                Row(label: "frida-server", value: dev.injectable ? "运行中" : "未安装/未运行",
                    ok: dev.injectable)
                Divider()
                Text("挂载 Developer Image 只让 frida 看得见应用和进程；真正解密必须靠设备上的 frida-server，两步都得到位。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button { model.mountDDI() } label: {
                        Label("挂载 DDI", systemImage: "arrow.down.circle")
                    }
                    .disabled(model.busy)
                    Button { model.prepareFridaServer() } label: {
                        Label("推送 frida-server", systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.busy || model.env.clientFridaVersion == nil)
                }
                if !model.actionsLog.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(model.actionsLog.suffix(30), id: \.self) { l in
                                Text(l).font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxHeight: 130)
                    .padding(7)
                    .background(Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 5))
                }
            } else {
                Text("没有选中设备").foregroundStyle(.secondary)
            }
        }
    }
}

struct TipsCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Card(title: "设备上装 frida-server", icon: "hammer") {
            VStack(alignment: .leading, spacing: 6) {
                step(1, "点上面的「推送 frida-server」，会把和 Mac 端同版本的 .deb 送进手机的 /var/mobile/Media。")
                step(2, "手机上打开 Filza，进入 私人 → Var → Mobile → Media，点这个 .deb。")
                step(3, "选右下角「通过 dpkg 安装」，装完 LaunchDaemon 会自动拉起 frida-server。")
                step(4, "回到这里点「重新扫描」，可注入变成“是”就能开砸。")
                Divider()
                Text("备选：Sileo 添加源 https://build.frida.re 安装 Frida；或用数据线连电脑后在 Sileo 里装 OpenSSH，那样还能顺带加速 bundle 拉取。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func step(_ n: Int, _ s: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("\(n).").font(.callout.weight(.semibold)).foregroundStyle(.teal)
            Text(s).font(.callout)
        }
    }
}

struct GeneralSettingsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var s = AppSettings.shared
    @ObservedObject private var mac = AppModel.shared.macFairPlay

    var body: some View {
        Form {
            Section("输出") {
                LabeledContent("保存位置") {
                    HStack {
                        TextField("", text: $s.outputDir)
                            .frame(width: 260)
                        Button("选择…") { pickDir() }
                        Button("默认") { s.outputDir = "" }
                    }
                }
                Toggle("显示系统应用", isOn: $s.showSystemApps)
            }
            Section("Mac 离线砸壳") {
                LabeledContent("同时砸几个") {
                    ParallelCountField(value: Binding(
                        get: { mac.maxParallelStoreJobs },
                        set: { mac.setStoreParallelLimit($0) }))
                }
            }
            Section("手机砸壳") {
                Toggle("让 App 停在挂起状态（反调试规避）", isOn: $s.noResume)
                Toggle("砸壳成功后自动卸载手机上的该应用", isOn: $s.autoUninstall)
                LabeledContent("手机并行数量（1 至 6）") {
                    ParallelCountField(value: Binding(
                        get: { s.maxParallel },
                        set: { s.maxParallel = $0; s.save() }), maximum: 6)
                }
                Text("并行任务各自使用独立的设备端暂存文件，互不干扰；但都挤同一条 USB，"
                     + "2 到 3 个通常就是上限，太大反而更慢，也更容易占满手机存储。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("bundle 由设备端 root shell 打包后经 AFC 拉回，实测约 30 MB/s。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("App Store") {
                LabeledContent("商店地区") {
                    Picker("", selection: Binding(
                        get: { model.storeRegion },
                        set: { model.selectStoreRegion($0) })) {
                        ForEach(StoreRegion.allCases) { region in
                            Text(region.title).tag(region.rawValue)
                        }
                    }.labelsHidden().frame(width: 110)
                }
                Toggle("App Store 装的 App 砸完自动卸载", isOn: $s.storeAutoUninstall)
                LabeledContent("ipatool") {
                    HStack {
                        TextField("留空则用内置/缓存/自动下载", text: $s.ipatoolPath)
                            .frame(width: 260)
                        Button("自动") { s.ipatoolPath = "" }
                    }
                }
                Label("下载会话由随包的“初始化下载会话.command”管理。",
                      systemImage: "terminal")
                    .font(.caption).foregroundStyle(.secondary)
                Text("每个地区使用独立会话。切换地区后运行初始化脚本，选择对应地区并登录对应 Apple ID。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear { s.save() }
    }

    private func pickDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            s.outputDir = panel.url?.path ?? ""
        }
    }
}
