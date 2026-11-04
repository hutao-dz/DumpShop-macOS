import SwiftUI

struct StoreVersion: Decodable, Identifiable, Equatable {
    let externalVersionID: String
    let displayVersion: String
    let releaseDate: String
    var error: String?
    var id: String { externalVersionID }
    var dateText: String { String(releaseDate.prefix(10)) }
}

private struct StoreVersionPage: Decodable {
    let e: String
    var versions: [StoreVersion]?
    var total: Int?
    var next_offset: Int?
    var m: String?
}

/// Both store surfaces use this picker; the region and account are pinned when opened.
struct StoreHistoryButton: View {
    let item: StoreItem
    @EnvironmentObject private var model: AppModel
    @State private var showing = false

    var body: some View {
        Button("历史版本", systemImage: "clock.arrow.circlepath") { showing = true }
            .disabled(!model.storeAuth.loggedIn || model.storeAuth.accountID.isEmpty)
            .sheet(isPresented: $showing) {
                StoreHistorySheet(item: item, region: model.storeRegion,
                                  accountID: model.storeAuth.accountID)
                    .environmentObject(model)
            }
    }
}

private struct StoreHistorySheet: View {
    let item: StoreItem
    let region: String
    let accountID: String
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [StoreVersion] = []
    @State private var selection: StoreVersion?
    @State private var total = 0
    @State private var nextOffset: Int? = 0
    @State private var busy = false
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(item.name) · 历史版本").font(.title3.bold())
            Text("\(StoreRegion.title(region)) · 仅使用当前账号已有下载授权；部分版本可能已不可下载。")
                .font(.caption).foregroundStyle(.secondary)
            List(rows) { row in
                Button { selection = row } label: {
                    HStack(alignment: .top) {
                        Image(systemName: selection?.id == row.id ? "checkmark.circle.fill" : "circle")
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.displayVersion.isEmpty ? "版本信息未取得" : "版本 \(row.displayVersion)")
                            Text(row.error ?? "发布日期 \(row.dateText)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("ID \(row.externalVersionID)").font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(row.displayVersion.isEmpty)
                .padding(.vertical, 4)
            }
            .frame(minHeight: 280)
            if !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                    Text("正在查询版本信息…").font(.caption)
                } else {
                    Text("已加载 \(rows.count) / \(total)").font(.caption).foregroundStyle(.secondary)
                    if nextOffset != nil {
                        Button(error.isEmpty ? "加载更多" : "重试") { Task { await loadPage() } }
                    }
                    Button("刷新") {
                        rows = []; selection = nil; nextOffset = 0
                        Task { await loadPage() }
                    }
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("下载所选版本") {
                    guard let selection, model.storeRegion == region,
                          model.storeAuth.accountID == accountID else { return }
                    model.downloadStoreForMacFairPlay(item, version: selection)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection == nil || model.storeRegion != region
                          || model.storeAuth.accountID != accountID
                          || !model.storeAuth.loggedIn || !model.macFairPlay.canStartStoreJob
                          || model.macFairPlay.activeStoreJob(bundleId: item.bundleId,
                              region: region, accountID: accountID) != nil)
            }
        }
        .padding(20)
        .frame(width: 610, height: 505)
        .task { await loadPage() }
        .onChange(of: model.storeRegion) { _, value in if value != region { dismiss() } }
        .onChange(of: model.storeAuth.accountID) { _, value in if value != accountID { dismiss() } }
    }

    private func loadPage() async {
        guard !busy, let offset = nextOffset else { return }
        guard let argv = model.storeArgv(["versions", "--bundle-id", item.bundleId,
            "--expected-account", accountID, "--offset", String(offset), "--limit", "8"],
            region: region) else {
            error = "Python 或地区下载组件未就绪"; return
        }
        busy = true; error = ""
        defer { busy = false }
        let result = await Runner.run(argv, timeout: 220)
        guard !Task.isCancelled else { return }
        for line in result.out.split(separator: "\n") {
            guard let data = String(line).data(using: .utf8),
                  let page = try? JSONDecoder().decode(StoreVersionPage.self, from: data) else { continue }
            if page.e == "error" { error = page.m ?? "版本查询失败" }
            if result.ok, page.e == "result", let versions = page.versions {
                rows += versions.filter { row in !rows.contains(where: { $0.id == row.id }) }
                total = page.total ?? rows.count
                nextOffset = page.next_offset
                return
            }
        }
        if error.isEmpty { error = "版本查询失败，请检查网络、会话和下载组件后重试" }
    }
}
