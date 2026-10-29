import AppKit
import Platform
import ServiceManagement
import SwiftUI
import UserNotifications

struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var notifier = Notifier.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("系统通知") {
                    HStack {
                        Text(notificationStatus).foregroundStyle(.secondary)
                        switch notifier.authorization {
                        case .notDetermined:
                            Button("允许通知") { Task { await notifier.requestAuthorization() } }
                        case .denied:
                            Button("打开系统设置") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        default:
                            EmptyView()
                        }
                    }
                }
            } footer: {
                Text("只在等待确认替换和运行失败时通知，点通知直接打开对应的运行。")
            }
            Section {
                Toggle("登录时打开", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError {
                    Label(loginError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            } footer: {
                Text("App 打开着才能处理推送；关闭窗口后仍在后台监听，退出后的推送会在下次打开时补处理。")
            }
            Section("数据") {
                LabeledContent("数据目录") {
                    Button("在访达中显示") {
                        if let paths = model.service?.paths {
                            NSWorkspace.shared.activateFileViewerSelecting([paths.applicationSupport])
                        }
                    }
                    .disabled(model.service == nil)
                }
            }
        }
        .formStyle(.grouped)
        .task { await notifier.refresh() }
    }

    private var notificationStatus: String {
        switch notifier.authorization {
        case .authorized, .provisional, .ephemeral: "已允许"
        case .denied: "已关闭"
        case .notDetermined: "尚未询问"
        @unknown default: "未知"
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "设置失败：\(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
