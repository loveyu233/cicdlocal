import SwiftUI

@main
struct LocalCICDApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("本地 CI", id: "main") {
            MainView()
                .environment(model)
        }
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加项目…") { model.addProject() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.service == nil)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra {
            StatusBarMenu().environment(model)
        } label: {
            Label("本地 CI", systemImage: model.menuBarSymbol)
                .accessibilityLabel("本地 CI")
                .accessibilityIdentifier("localcicd-status-item")
        }
        .menuBarExtraStyle(.menu)
    }
}
