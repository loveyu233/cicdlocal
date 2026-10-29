import SwiftUI

/// 设置窗口只有两页：k8s 连接和通用。
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("k8s 连接", systemImage: "server.rack") {
                ConnectionsSettingsView()
            }
            Tab("通用", systemImage: "gearshape") {
                GeneralSettingsView()
            }
        }
        .frame(width: 720, height: 440)
    }
}
