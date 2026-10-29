import AppKit
import Models

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminating = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        Notifier.shared.install()
        #if DEBUG
        // 界面测试按需固定深浅色，只影响当前测试进程。
        switch ProcessInfo.processInfo.environment["LOCALCICD_UI_TEST_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏是主窗口的快捷入口，继续保留普通 App 的程序坞与激活行为。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        ProcessInfo.processInfo.disableSuddenTermination()
        Task {
            await AppModel.shared.start()
            await Notifier.shared.refresh()
        }
    }

    /// 关闭窗口后继续监听推送；点程序坞图标重新打开窗口。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        guard let service = AppModel.shared.service else { return .terminateNow }
        terminating = true
        Task {
            var running = 0
            for project in (try? await service.database.projects()) ?? [] {
                running += ((try? await service.database.runs(projectID: project.id, limit: 50)) ?? [])
                    .filter { $0.status == .running || $0.status == .queued }.count
            }
            if running > 0 {
                let alert = NSAlert()
                alert.messageText = "还有 \(running) 个运行没有结束"
                alert.informativeText = "退出会终止正在执行的命令，下次打开时这些运行标为「已中断」，可以重新运行。已经执行的 docker push 和 kubectl 不会回滚。"
                alert.addButton(withTitle: "终止并退出")
                alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    terminating = false
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
            await AppModel.shared.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
