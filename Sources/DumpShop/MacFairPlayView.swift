import AppKit
import SwiftUI

struct MacFairPlaySettingsView: View {
    @ObservedObject var mac: MacFairPlayController
    @EnvironmentObject private var model: AppModel
    @State private var showExtract = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("商店地区", selection: Binding(
                        get: { model.storeRegion }, set: { model.selectStoreRegion($0) })) {
                        ForEach(StoreRegion.allCases) { region in
                            Text(region.title).tag(region.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    statusCard
                    if mac.credentialReady {
                        credentialCard
                        if !mac.storeJobs.isEmpty {
                            storeJobsCard
                        }
                        if showExtract { extractCard }
                    } else {
                        extractCard
                    }
                }
                .padding(18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            mac.refresh()
            showExtract = !mac.credentialReady
            model.refreshStoreAuth()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
                model.refreshStoreAuth()
            }
        .onChange(of: mac.credentialReady) { _, ready in
            if ready && mac.busy == false {
                showExtract = false
            }
        }
        .onChange(of: "\(model.storeRegion)|\(model.storeAuth.accountID)") { _, _ in
            if !mac.busy { mac.setupIPA = nil }
        }

    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .symbolEffect(.pulse, isActive: mac.busy)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mac.stage).font(.callout.weight(.medium))
                    Text(statusDetail)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if mac.busy { ProgressView().controlSize(.small) }
                chip(mac.credentialReady ? "账号凭据已就绪" : "需要首次提取",
                     tone: mac.credentialReady ? .ok : .warn)
            }
            if mac.busy {
                operationProgress
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(Color.secondary.opacity(0.18)))
    }

    private var operationProgress: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let fraction = mac.progressFraction {
                ProgressView(value: min(max(fraction, 0), 1))
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
            HStack(spacing: 8) {
                Text(mac.progressDetail.isEmpty ? mac.stage : mac.progressDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if let fraction = mac.progressFraction {
                    Text("\(Int((min(max(fraction, 0), 1) * 100).rounded()))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.teal)
                }
            }
        }
    }

    private var credentialCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label("账号凭据", systemImage: "key.horizontal.fill")
                    .font(.headline)
                Spacer()
                Button(showExtract ? "收起设置" : "添加账号") {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showExtract.toggle()
                    }
                }
                .buttonStyle(.borderless)
            }
            StoreAccountCredentialPicker(mac: mac)
            Label("普通 App 凭据只适用于同一个 Apple 账号；Apple Arcade 需要单独凭据。",
                  systemImage: "person.badge.key")
                .font(.caption).foregroundStyle(.secondary)
            Text("账号名称只是备注。不选择定位 IPA 时，会使用手机上第一个可用 App 的授权，可能属于其他账号。")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("管理本地凭据") {
                HStack(spacing: 10) {
                    Picker("本地凭据", selection: $mac.selectedCredentialPath) {
                        ForEach(mac.credentials) { credential in
                            Text(credential.title).tag(credential.path)
                        }
                    }
                    Button(role: .destructive) {
                        mac.deleteSelectedCredential()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("删除所选本地凭据")
                    .disabled(mac.busy || mac.selectedCredential == nil)
                }
                .padding(.top, 8)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(Color.secondary.opacity(0.18)))
    }

    private var extractCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("首次设置", systemImage: "cable.connector")
                    .font(.headline)
                Spacer()
                if mac.credentialReady {
                    Button(showExtract ? "收起" : "添加账号") {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showExtract.toggle()
                        }
                    }
                }
                Button {
                    mac.refreshDevices()
                } label: {
                    Label("重新检测", systemImage: "arrow.clockwise")
                }
                .disabled(mac.busy)
            }

            if showExtract {
                Grid(alignment: .leadingFirstTextBaseline,
                     horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("连接设备").font(.callout)
                        if mac.devices.isEmpty {
                            HStack(spacing: 7) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text("未检测到设备，请解锁并点“信任”")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Picker("", selection: $mac.selectedDeviceUDID) {
                                ForEach(mac.devices) { device in
                                    Text(device.title).tag(device.udid)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 360, alignment: .leading)
                        }
                    }
                    GridRow {
                        Text("账号名称").font(.callout)
                        TextField("例如：主账号", text: $mac.credentialLabel)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 210)
                    }
                    GridRow {
                        Text("登录账户").font(.callout)
                        Picker("", selection: $mac.sshLoginMode) {
                            Text("root").tag("root")
                            Text("Dopamine mobile + sudo").tag("dopamine")
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 270, alignment: .leading)
                    }
                    GridRow {
                        Text("USB SSH").font(.callout)
                        HStack(spacing: 9) {
                            TextField("2222", text: $mac.sshPort)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 76)
                            SecureField(
                                mac.sshLoginMode == "dopamine"
                                    ? "Dopamine mobile 密码"
                                    : "密码，留空则使用 SSH 密钥",
                                text: $mac.sshPassword)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                        }
                    }
                    GridRow {
                        Text("账号定位").font(.callout)
                        VStack(alignment: .leading, spacing: 4) {
                            fileButton(
                                url: mac.setupIPA?.pathExtension == "sinf" ? nil : mac.setupIPA,
                                placeholder: "选择对应账号的 IPA") {
                                    mac.chooseSetupIPA()
                            }
                            if mac.repairLicense(region: model.storeRegion,
                                                 accountID: model.storeAuth.accountID) != nil {
                                Text("已自动准备该地区下载账号的授权定位，无需手动选择。")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else if !mac.credentials.isEmpty {
                                Text("添加其他账号时需先定位授权，避免重复提取同一账号。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                HStack(alignment: .center, spacing: 10) {
                    Label("密码只在本次提取的子进程环境中使用，不写入日志或配置。",
                          systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        mac.extractCredential(region: model.storeRegion, accountID: model.storeAuth.accountID)
                    } label: {
                        Label("提取账号凭据", systemImage: "key.viewfinder")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(mac.busy || mac.selectedDevice == nil)
                }

                Text(mac.sshLoginMode == "dopamine"
                    ? "先在 Dopamine 的“设置”里修改 “mobile” 密码，再在这里输入该密码。"
                    : "手机需要 root SSH，并安装过这个 Apple 账号的 App Store 应用。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(Color.secondary.opacity(0.18)))
    }

    private var storeJobsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("离线任务", systemImage: "square.stack.3d.up.fill")
                    .font(.headline)
                chip("并行 \(mac.activeStoreCount)/\(mac.maxParallelStoreJobs)", tone: .info)
                Spacer()
                Button("清除已完成") {
                    mac.clearFinishedStoreJobs()
                }
                .disabled(!mac.storeJobs.contains { !$0.state.isActive })
            }
            ForEach(mac.storeJobs) { job in
                MacStoreJobRow(job: job)
                if job.id != mac.storeJobs.last?.id {
                    Divider()
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(Color.secondary.opacity(0.18)))
    }

    private func fileButton(url: URL?, placeholder: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: url == nil ? "plus.circle" : "doc.fill")
                    .foregroundStyle(url == nil ? Color.secondary : Color.teal)
                Text(url?.lastPathComponent ?? placeholder)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("选择…").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.55),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(Color.secondary.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .disabled(mac.busy)
    }

    private var statusDetail: String {
        if mac.busy { return mac.stage }
        if mac.credentialReady && mac.devices.isEmpty {
            return "账号凭据已保存 · 当前不需要连接 iPhone"
        }
        if mac.devices.isEmpty { return "USB: 未检测到 · SSH: \(mac.sshPort)" }
        return "USB: \(mac.selectedDevice?.name ?? "iPhone") · SSH: \(mac.sshPort)"
    }

    private var statusIcon: String {
        if mac.busy { return "arrow.triangle.2.circlepath" }
        return mac.credentialReady ? "checkmark.shield.fill" : "iphone.circle"
    }

    private var statusColor: Color {
        if mac.busy { return .teal }
        return mac.credentialReady ? .green : .orange
    }
}

struct StoreAccountCredentialPicker: View {
    @ObservedObject var mac: MacFairPlayController
    @EnvironmentObject private var model: AppModel
    @State private var draftPath = ""
    @State private var loadedAccountKey = ""

    private var accountKey: String {
        MacFairPlayController.credentialBindingKey(
            region: model.storeRegion, accountID: model.storeAuth.accountID)
    }

    private var savedPath: String {
        mac.credential(region: model.storeRegion, accountID: model.storeAuth.accountID)?.path ?? ""
    }

    private var accountReady: Bool {
        model.storeAuth.loggedIn && !model.storeAuth.accountID.isEmpty
    }

    private var canSave: Bool {
        accountReady && loadedAccountKey == accountKey && draftPath != savedPath
            && mac.credentials.contains { $0.path == draftPath }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Picker("\(StoreRegion.title(model.storeRegion))账号的解密凭据", selection: $draftPath) {
                Text("请选择同一 Apple 账号的凭据").tag("")
                ForEach(mac.credentials) { credential in
                    Text(credential.title).tag(credential.path)
                }
            }
            .disabled(!accountReady)
            Text(model.storeAuth.loggedIn
                 ? "当前下载账号：\(model.storeAuth.account)。请选择由此账号的 App 提取的凭据。"
                 : "先初始化此地区的下载会话，再绑定解密凭据。")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button {
                    guard canSave else { return }
                    mac.bindCredential(path: draftPath, region: model.storeRegion,
                                       accountID: model.storeAuth.accountID)
                } label: {
                    Label("保存", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                if accountReady && loadedAccountKey == accountKey {
                    Text(draftPath != savedPath ? "未保存" : (savedPath.isEmpty ? "尚未绑定" : "已保存"))
                        .font(.caption)
                        .foregroundStyle(draftPath != savedPath ? Color.orange : Color.secondary)
                }
            }
            if !model.storeAuth.error.isEmpty {
                Text(model.storeAuth.error)
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .onAppear { restoreSavedSelection() }
        .onChange(of: accountKey) { _, _ in restoreSavedSelection() }
        .onChange(of: savedPath) { _, _ in restoreSavedSelection() }
        .onChange(of: mac.credentials.map(\.path)) { _, paths in
            if !paths.contains(draftPath) { restoreSavedSelection() }
        }
    }

    private func restoreSavedSelection() {
        loadedAccountKey = accountKey
        draftPath = savedPath
    }
}

private struct MacStoreJobRow: View {
    let job: MacStoreJob
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.item.name)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text("\(job.stage) · v\(job.requestedVersion?.displayVersion ?? job.item.version)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                chip(job.state.rawValue, tone: tone)
                if let output = job.outputURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([output])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("在访达中显示")
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showLog.toggle()
                    }
                } label: {
                    Image(systemName: "text.alignleft")
                }
                .buttonStyle(.borderless)
                .help(showLog ? "收起日志" : "查看日志")
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

            HStack(spacing: 8) {
                Text(job.progressDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                if job.state == .completed, let verified = job.verified {
                    Text(verified ? "全解密已校验" : "仍有加密镜像")
                        .font(.caption2)
                        .foregroundStyle(verified ? Color.green : Color.orange)
                }
                if job.state.isActive, let fraction = job.progressFraction {
                    Text("\(Int((min(max(fraction, 0), 1) * 100).rounded()))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.teal)
                }
            }

            if let output = job.outputURL {
                Text(output.lastPathComponent)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if showLog {
                HStack {
                    Text("日志 \(job.log.count) 行")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("复制全部") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(job.log.joined(separator: "\n"), forType: .string)
                    }
                    .buttonStyle(.borderless)
                    .disabled(job.log.isEmpty)
                }
                ScrollView {
                    Text(job.log.isEmpty ? "（暂无输出）" : job.log.joined(separator: "\n"))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .frame(minHeight: 80, maxHeight: 150)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .padding(.vertical, 2)
    }

    private var tone: ChipTone {
        switch job.state {
        case .completed: return .ok
        case .failed: return .warn
        case .verifying: return .info
        case .downloading, .decrypting: return .info
        }
    }

    private var color: Color {
        switch job.state {
        case .completed: return .green
        case .failed: return .orange
        default: return .teal
        }
    }

    private var icon: String {
        switch job.state {
        case .downloading: return "arrow.down.circle.fill"
        case .decrypting: return "lock.open.fill"
        case .verifying: return "checkmark.shield.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}
