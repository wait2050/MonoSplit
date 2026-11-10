import AppKit
import SwiftUI
import MonoSplitCore

@main
struct MonoSplitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    @AppStorage("appearance") private var appearance: AppAppearance = .system
    var body: some Scene {
        Window("MonoSplit · 三路分频", id: "tuning") {
            MainView(model: model)
                .frame(minWidth: 1060, minHeight: 720)
                .preferredColorScheme(appearance.colorScheme)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1240, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("撤销参数修改") { model.undo() }.keyboardShortcut("z").disabled(!model.history.canUndo)
                Button("重做参数修改") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.history.canRedo)
            }
            CommandMenu("外观") {
                Picker("外观", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { option in Text(option.rawValue).tag(option) }
                }
                Divider()
                Button("紧凑窗口") { NSApp.keyWindow?.setContentSize(NSSize(width: 1060, height: 720)) }
                Button("标准窗口") { NSApp.keyWindow?.setContentSize(NSSize(width: 1240, height: 820)) }
            }
        }
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.snapshot.running ? "waveform.path" : "line.3.horizontal.decrease.circle")
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system = "跟随系统", light = "浅色", dark = "深色"
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
