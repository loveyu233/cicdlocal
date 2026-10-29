import AppKit
import Carbon
import XCTest

/// 只在 scripts/test-ui.py 准备的 cicddemo 隔离副本上运行：导入两个假 k8s 连接、添加项目、开启推送监听，
/// 脚本检测到监听后执行一次本地 git push，这里检查三阶段、日志和确认替换，最后用深色外观再截一遍图。
nonisolated final class AppUITests: XCTestCase {
    @MainActor private var app: XCUIApplication!
    @MainActor private var inputSource: TestInputSource?

    @MainActor
    func testPushToConfirmedDeploy() throws {
        continueAfterFailure = false
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: source.appending(path: "build/ui-test-fixture.json")))
        let root = URL(fileURLWithPath: fixture.root)
        XCTAssertEqual(try String(contentsOf: root.appending(path: "repository/.git/localcicd-test-source"), encoding: .utf8),
                       fixture.source)
        let app = XCUIApplication()
        self.app = app
        app.launchEnvironment["LOCALCICD_UI_TEST_ROOT"] = root.path
        app.launchEnvironment["LOCALCICD_TEST_SOURCE"] = fixture.source
        app.launchEnvironment["LOCALCICD_UI_TEST_APPEARANCE"] = "light"
        addTeardownBlock { await MainActor.run { if app.state != .notRunning { app.terminate() } } }
        app.launch()
        let window = app.windows["main"]
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["add-project"].waitForExistence(timeout: 20))
        capture(window, "空状态·light")

        // 设置：导入两个 kubeconfig 并分别命名。
        let settings = openSettings(tab: "k8s 连接")
        for (name, file) in [("测试环境", fixture.kubeconfigs[0]), ("正式环境", fixture.kubeconfigs[1])] {
            click(settings.buttons["import-connection"])
            let sheet = settings.sheets.firstMatch
            click(sheet.buttons["选择文件…"])
            choose(file, prompt: "选择")
            XCTAssertTrue(text(sheet, "https://127.0.0.1:6443").waitForExistence(timeout: 10), "应显示集群地址预览")
            XCTAssertFalse(sheet.buttons["connection-import-confirm"].isEnabled, "没有名字不能导入")
            fill(sheet.textFields["connection-name"], name)
            click(sheet.buttons["connection-import-confirm"])
            XCTAssertTrue(text(settings.outlines["connection-table"], name).waitForExistence(timeout: 10))
        }
        capture(settings, "设置·k8s 连接·light")
        selectTab(settings, "通用")
        capture(settings, "设置·通用·light")
        settings.typeKey("w", modifierFlags: .command)

        // 添加项目：通过系统打开面板选择仓库目录。
        click(app.buttons["add-project"])
        choose(root.appending(path: "repository").path, prompt: "添加项目")
        XCTAssertTrue(text(window, "配置有效（当前提交）").waitForExistence(timeout: 20), "隔离副本的 .local.cicd.yml 应校验通过")
        XCTAssertTrue(text(window, "需确认").exists && text(window, "自动").exists, "应列出自动和需确认的替换目标")
        capture(window, "项目概览·light")

        let toggle = window.checkBoxes["push-listening-toggle"].exists ? window.checkBoxes["push-listening-toggle"] : window.switches["push-listening-toggle"]
        click(toggle)
        let enable = app.buttons["enable-listening-confirm"]
        XCTAssertTrue(enable.waitForExistence(timeout: 10), "应弹出开启推送监听的确认")
        capture(window, "开启推送监听·light")
        click(enable)
        wait(toggle, "value == 1", 20, "推送监听应已开启")

        // 脚本此时执行 git push；运行出现后进入详情。
        let row = window.descendants(matching: .any).matching(identifier: "run-row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 120), "git push 后应出现运行")
        click(row)
        let confirm = window.buttons["confirm-deploy"]
        wait(window.buttons["stage-6"], "value == '等待确认'", 120, "后一个服务的正式批次应独立就绪")
        wait(window.buttons["stage-0"], "value == '成功'", 5, "测试阶段应成功")
        wait(window.buttons["stage-1"], "value == '运行中'", 5, "前一个服务的构建应仍被屏障阻塞")
        wait(window.buttons["stage-2"], "value == '成功'", 5, "后一个镜像应已成功")
        wait(window.buttons["stage-3"], "value == '未开始'", 5, "主服务部署尚不可用")
        click(window.buttons["stage-6"])
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "构建其他服务期间也必须能点击确认")
        capture(window, "运行详情·等待确认·light")
        openStatusMenu()
        XCTAssertTrue(app.menuItems["等待确认 1 · 最新失败 0"].exists, "其他镜像仍在构建时菜单栏也应显示等待确认")
        capture(statusItem.menus.firstMatch, "菜单栏·运行与等待·light")
        click(statusItem.menuItems["repository"])
        click(statusItem.menuItems.matching(NSPredicate(format: "title BEGINSWITH '#'")).firstMatch)
        click(statusItem.menuItems["查看并确认替换…"])
        XCTAssertTrue(window.buttons["confirm-deploy"].waitForExistence(timeout: 10), "菜单栏应定位到现有部署确认面板")

        // 日志：长行按窗口宽度换行，整段可以选中复制。
        click(window.buttons["stage-0"])
        let log = window.textViews["stage-log-text"]
        wait(log, "value CONTAINS %@", 20, "应显示测试阶段日志", fixture.marker)
        let scroll = window.scrollViews.containing(.textView, identifier: "stage-log-text").firstMatch
        XCTAssertLessThanOrEqual(log.frame.width, scroll.frame.width + 1, "长行应自动换行，不应横向撑开")
        let copied = withPasteboard { () -> String in
            log.click()
            log.typeKey("a", modifierFlags: .command)
            log.typeKey("c", modifierFlags: .command)
            return NSPasteboard.general.string(forType: .string) ?? ""
        }
        XCTAssertTrue(copied.contains(fixture.marker) && copied.contains("go version"), "全选应复制整段日志")
        capture(window, "测试日志·light")

        // 确认按钮在等待确认阶段的日志位置，选中别的阶段时不显示。
        XCTAssertFalse(confirm.exists)
        click(window.buttons["stage-6"])
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        click(confirm)
        click(app.sheets.buttons["确认替换"].exists ? app.sheets.buttons["确认替换"] : app.dialogs.buttons["确认替换"])
        wait(window.buttons["stage-6"], "value == '成功'", 120, "最后一批应先完成部署")
        wait(window.buttons["stage-1"], "value == '运行中'", 5, "后批部署完成时前一个构建仍在运行")
        capture(window, "后批已部署·前镜像仍构建·light")
        // 测试 Runner 只有仓库读取权限；由宿主脚本收到断言完成信号后释放构建屏障。
        print("LOCALCICD_UI_RELEASE_APP \(root.lastPathComponent)")
        wait(window.buttons["stage-5"], "value == '等待确认'", 30, "主服务构建完成后其正式批次可确认")
        click(window.buttons["stage-5"])
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        click(confirm)
        click(app.sheets.buttons["确认替换"].exists ? app.sheets.buttons["确认替换"] : app.dialogs.buttons["确认替换"])
        wait(window.staticTexts["run-status"], "label == '成功' OR value == '成功'", 120, "所有独立批次完成后运行应成功")
        XCTAssertFalse(confirm.exists)
        for index in [1, 3, 4, 5, 6] {
            wait(window.buttons["stage-\(index)"], "value == '成功'", 5, "各构建和部署均应成功")
        }
        capture(window, "运行详情·成功·light")
        quit()

        // 深色外观：重启后运行记录、概览和设置仍在。
        app.launchEnvironment["LOCALCICD_UI_TEST_APPEARANCE"] = "dark"
        app.launch()
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        XCTAssertTrue(text(window, "配置有效（当前提交）").waitForExistence(timeout: 20))
        capture(window, "项目概览·dark")
        click(row)
        wait(window.staticTexts["run-status"], "label == '成功' OR value == '成功'", 20, "重启后运行仍为成功")
        click(window.buttons["stage-5"])
        XCTAssertTrue(window.textViews["stage-log-text"].waitForExistence(timeout: 20))
        capture(window, "运行详情·dark")
        // 主窗口关闭后菜单栏仍可用，重新打开保留已有运行选择。
        window.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(window.exists)
        openStatusMenu()
        XCTAssertTrue(app.menuItems["运行中 0 · 排队 0"].exists)
        XCTAssertTrue(app.menuItems["等待确认 0 · 最新失败 0"].exists)
        capture(statusItem.menus.firstMatch, "菜单栏·主窗口关闭·dark")
        click(app.menuItems["打开本地 CI"])
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        wait(window.staticTexts["run-status"], "label == '成功' OR value == '成功'", 10, "菜单栏重新打开应保留运行选择")
        _ = openSettings(tab: "k8s 连接")
        capture(settings, "设置·k8s 连接·dark")

        // 删除连接：提示仍被项目引用，删除后钥匙串条目一并移除。
        let table = settings.outlines["connection-table"]
        for name in ["测试环境", "正式环境"] {
            click(text(table, name))
            click(settings.buttons["删除"])
            let dialog = settings.sheets.firstMatch
            XCTAssertTrue(dialog.staticTexts.matching(NSPredicate(format: "label CONTAINS 'repository' OR value CONTAINS 'repository'")).firstMatch.waitForExistence(timeout: 10),
                          "删除前应提示引用这个连接的项目")
            click(dialog.buttons["删除连接"])
            wait(text(table, name), "exists == false", 10, "连接应已删除")
        }
        settings.typeKey("w", modifierFlags: .command)
        quit()
    }

    // MARK: - 辅助

    @MainActor
    private var statusItem: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "localcicd-status-item").firstMatch
    }

    @MainActor
    private func openStatusMenu() {
        click(statusItem)
        XCTAssertTrue(app.menuItems["打开本地 CI"].waitForExistence(timeout: 10))
    }

    /// 从 App 菜单打开设置窗口并切到指定页；⌘, 在中文输入法下可能被输入法吃掉，菜单更可靠。
    /// 设置窗口会记住上次的页，所以每次都显式选择。
    @MainActor
    private func openSettings(tab: String) -> XCUIElement {
        click(app.menuBars.menuBarItems["LocalCICD"])
        click(app.menuBars.menuBarItems["LocalCICD"].menuItems["设置…"])
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "应打开设置窗口")
        selectTab(settings, tab)
        return settings
    }

    @MainActor
    private func selectTab(_ settings: XCUIElement, _ tab: String) {
        click(settings.radioButtons[tab].exists ? settings.radioButtons[tab] : settings.buttons[tab])
    }

    /// 在打开面板里用「前往文件夹」输入路径，然后按面板的确认按钮。
    @MainActor
    private func choose(_ path: String, prompt: String) {
        let panel = app.windows["open-panel"].exists ? app.windows["open-panel"] : app.dialogs.firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10), "应弹出系统打开面板")
        panel.typeKey("g", modifierFlags: [.command, .shift])
        let field = panel.sheets.firstMatch.textFields.firstMatch.exists
            ? panel.sheets.firstMatch.textFields.firstMatch : panel.descendants(matching: .textField).element(boundBy: 0)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "应显示前往文件夹输入框")
        selectASCIIInput()
        field.typeKey("a", modifierFlags: .command)
        withPasteboard { () -> Void in
            NSPasteboard.general.setString(path, forType: .string)
            field.typeKey("v", modifierFlags: .command)
        }
        field.typeKey(.return, modifierFlags: [])
        let button = panel.buttons[prompt]
        wait(button, "enabled == true", 10, "面板确认按钮应可用")
        button.click()
        wait(panel, "exists == false", 10, "打开面板应关闭")
    }

    /// SwiftUI 文本有时只把内容放在 value 里、label 为空，所以两者都匹配。
    @MainActor
    private func text(_ container: XCUIElement, _ string: String) -> XCUIElement {
        container.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", string, string)).firstMatch
    }

    @MainActor
    private func fill(_ field: XCUIElement, _ value: String) {
        click(field)
        selectASCIIInput()
        field.typeKey("a", modifierFlags: .command)
        withPasteboard { () -> Void in
            NSPasteboard.general.setString(value, forType: .string)
            field.typeKey("v", modifierFlags: .command)
        }
    }

    /// 借用剪贴板完成粘贴或复制，结束后恢复用户原来的剪贴板内容。
    @MainActor
    private func withPasteboard<T>(_ body: () -> T) -> T {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        pasteboard.clearContents()
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            })
        }
        return body()
    }

    @MainActor
    private func click(_ element: XCUIElement) {
        app.activate()
        XCTAssertTrue(element.waitForExistence(timeout: 20), "找不到界面元素：\(element)")
        // 直接轮询 isHittable：菜单栏项用 `hittable == 1` 谓词等待会一直不成立。
        // 测试期间其他 App 可能抢到前台，App 菜单和被遮住的控件就点不到，所以每轮都重新激活。
        let deadline = Date().addingTimeInterval(20)
        while !(element.isEnabled && element.isHittable) {
            guard Date() < deadline else { return XCTFail("界面元素尚未就绪：\(element)") }
            app.activate()
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        element.click()
    }

    @MainActor
    private func wait(_ element: XCUIElement, _ format: String, _ timeout: TimeInterval, _ message: String, _ arguments: Any...) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argumentArray: arguments), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, message)
    }

    @MainActor
    private func capture(_ element: XCUIElement, _ name: String) {
        app.activate()
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 粘贴前切到 ASCII 键盘布局，避免输入法浮层挡住输入框；测试结束后恢复。
    @MainActor
    private func selectASCIIInput() {
        if inputSource == nil {
            let source = TestInputSource()
            inputSource = source
            addTeardownBlock { await source.restore() }
        }
        inputSource?.selectASCII()
    }

    @MainActor
    private func quit() {
        app.activate()
        for _ in 0..<3 where app.sheets.firstMatch.exists || app.dialogs.firstMatch.exists {
            app.typeKey(.escape, modifierFlags: [])
        }
        app.typeKey("q", modifierFlags: .command)
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 30), "App 应正常退出")
    }

    private struct Fixture: Decodable {
        var root: String
        var source: String
        var kubeconfigs: [String]
        var marker: String
    }
}

@MainActor
private final class TestInputSource {
    private let original = TISCopyCurrentKeyboardInputSource().takeRetainedValue()

    func selectASCII() {
        let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        XCTAssertEqual(TISSelectInputSource(source), noErr, "应能选择系统 ASCII 键盘布局")
    }

    func restore() {
        XCTAssertEqual(TISSelectInputSource(original), noErr, "测试后应恢复原输入源")
    }
}
