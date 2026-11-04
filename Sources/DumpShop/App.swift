import AppKit
import SwiftUI

struct DumpShopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("砸壳工坊", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1100, minHeight: 720)
        }
        .defaultSize(width: 1340, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("环境…") { model.presentSettings(.environment) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("设备") {
                Button("重新扫描") { model.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("挂载 Developer Image") { model.mountDDI() }
                    .disabled(model.selectedDevice == nil || model.busy)
            }
            CommandMenu("离线解密") {
                Button("搜索 App Store 并离线砸壳…") {
                    model.presentSettings(.offline)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }

        Settings { SettingsView().environmentObject(model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        applyDockIcon()
        Task { @MainActor in AppModel.shared.start() }
    }

    private func applyDockIcon() {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = icon
    }
}
