import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, offline, environment, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .offline: return "离线砸壳"
        case .environment: return "环境"
        case .about: return "关于"
        }
    }

    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .offline: return "person.badge.key"
        case .environment: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                WorkshopBrandIcon().frame(width: 42, height: 42).padding(.bottom, 20)
                WorkshopEyebrow(text: "PREFERENCES").padding(.bottom, 10)
                ForEach(SettingsPage.allCases) { page in
                    Button { model.settingsPage = page } label: {
                        Label(page.title, systemImage: page.icon)
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .foregroundStyle(model.settingsPage == page ? WorkshopPalette.accent : WorkshopPalette.muted)
                            .background(model.settingsPage == page ? WorkshopPalette.soft : .clear,
                                        in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(22).frame(width: 200)
            .background(WorkshopPalette.surface)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text(model.settingsPage.title)
                    .font(.title2.weight(.semibold))
                    .padding(20)
                Divider()
                Group {
                    switch model.settingsPage {
                    case .general: GeneralSettingsView()
                    case .offline: MacFairPlaySettingsView(mac: model.macFairPlay)
                    case .environment: EnvironmentSettingsView()
                    case .about: AboutSettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(minWidth: 620, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 840, idealWidth: 1000, minHeight: 620, idealHeight: 740)
        .background(WorkshopPalette.background)
        .foregroundStyle(WorkshopPalette.ink)
        .tint(WorkshopPalette.accent)
        .navigationTitle("设置")
    }
}

struct ParallelCountField: View {
    @Binding var value: Int
    var maximum: Int? = nil
    @State private var text = ""
    @FocusState private var focused: Bool

    private var parsed: Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let count = Int(text), count > 0,
              maximum.map({ count <= $0 }) ?? true else { return nil }
        return count
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            TextField("数量", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
                .focused($focused)
                .onSubmit { if parsed == nil { text = String(value) } }
            if parsed == nil && !text.isEmpty {
                Text(maximum.map { "请输入 1 至 \($0) 的整数" } ?? "请输入大于 0 的整数")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .onAppear { text = String(value) }
        .onChange(of: text) { _, _ in
            if let count = parsed, count != value { value = count }
        }
        .onChange(of: value) { _, count in
            if !focused { text = String(count) }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { text = String(value) }
        }
    }
}

private struct AboutSettingsView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "版本 \(info["CFBundleShortVersionString"] as? String ?? "")"
            + "（\(info["CFBundleVersion"] as? String ?? "")）"
    }

    var body: some View {
        VStack(spacing: 16) {
            WorkshopBrandIcon().frame(width: 88, height: 88)
            Text("砸壳工坊").font(.title.weight(.semibold))
            Text(version).font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
                GridRow {
                    Text("作者").foregroundStyle(.secondary)
                    Text("安桃网络")
                }

            }
            .font(.body)
            .padding(.vertical, 16)
            VStack(spacing: 9) {
                Text("感谢开源，让更多可能发生。")
                    .font(.system(size: 12)).foregroundStyle(WorkshopPalette.muted)
                Link("Ethan Arbuckle · fairplay-decrypt ↗", destination: URL(string: "https://github.com/EthanArbuckle/fairplay-decrypt")!)
                Link("majd · ipatool ↗", destination: URL(string: "https://github.com/majd/ipatool")!)
            }.font(.system(size: 11))
            Text("© \(String(Calendar.current.component(.year, from: Date()))) 安桃网络 版权所有。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
