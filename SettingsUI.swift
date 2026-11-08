import Cocoa
import ServiceManagement

@MainActor
private final class ShortcutButton: NSButton {
    var onBegin: (() -> Void)?
    var onKey: ((KeyCombination) -> Void)?
    var onCancel: (() -> Void)?
    private(set) var waiting = false
    override var acceptsFirstResponder: Bool { true }
    func begin() {
        guard !waiting else { return }
        window?.makeFirstResponder(self)
        waiting = true; title = "请按组合键… Esc 取消"
        onBegin?()
    }
    func cancel() {
        guard waiting else { return }; waiting = false; onCancel?()
    }
    override func resignFirstResponder() -> Bool { cancel(); return super.resignFirstResponder() }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if waiting { handle(event); return true }; return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if waiting { handle(event) } else { super.keyDown(with: event) }
    }
    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty { cancel(); return }
        do {
            let key = try KeyCombination.from(event)
            waiting = false; onKey?(key)
        } catch {
            NSSound.beep() // Stay in capture mode; user can correct without losing the old binding.
            toolTip = error.localizedDescription
        }
    }
}

@MainActor
final class SettingsUI: NSObject, NSWindowDelegate {
    private let hotKeys: GlobalHotKeys
    private let getVisibility: () -> Bool
    private let setVisibility: (Bool) -> Void
    private var window: NSWindow?
    private var keyButtons = [AppAction: ShortcutButton]()
    private let visibilityButton = NSButton(checkboxWithTitle: "显示桌面宠物", target: nil, action: nil)
    private let saveScreenshotButton = NSButton(checkboxWithTitle: "截图后选择保存到文件", target: nil, action: nil)
    private let loginButton = NSButton(checkboxWithTitle: "开机自动启动", target: nil, action: nil)
    private let loginState = NSTextField(labelWithString: "")
    private let feedback = NSTextField(wrappingLabelWithString: "点击“设置快捷键”，按下组合键即可保存。Esc 取消；可随时清除。")
    init(hotKeys: GlobalHotKeys, getVisibility: @escaping () -> Bool, setVisibility: @escaping (Bool) -> Void) {
        self.hotKeys = hotKeys; self.getVisibility = getVisibility; self.setVisibility = setVisibility
        super.init()
    }
    func show() {
        if window == nil { build() }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
    private func build() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ClawdSnip · 设置"; window.isReleasedWhenClosed = false; window.delegate = self
        window.center(); self.window = window
        let content = window.contentView!
        func place(_ view: NSView, x: CGFloat = 24, y: CGFloat, w: CGFloat = 512, h: CGFloat = 24) {
            view.frame = NSRect(x: x, y: y, width: w, height: h); content.addSubview(view)
        }
        let title = NSTextField(labelWithString: "快捷键与偏好")
        title.font = .systemFont(ofSize: 21, weight: .semibold); place(title, y: 566, h: 30)
        let hint = NSTextField(labelWithString: "全局快捷键：在其他应用里也能使用，需包含 ⌘、⌥ 或 ⌃。")
        hint.font = .systemFont(ofSize: 12); hint.textColor = .secondaryLabelColor
        place(hint, y: 533)
        for (index, action) in AppAction.allCases.enumerated() {
            let y = CGFloat(486 - index * 45)
            place(NSTextField(labelWithString: action.title), y: y, w: 160)
            let record = ShortcutButton(title: "设置快捷键…", target: self, action: #selector(recordKey(_:)))
            record.bezelStyle = .rounded; record.tag = Int(action.rawValue)
            record.onBegin = { [weak self] in self?.hotKeys.suspend() }
            record.onKey = { [weak self] key in self?.apply(action, key: key) }
            record.onCancel = { [weak self] in self?.resumeKeys() }
            place(record, x: 193, y: y - 2, w: 260, h: 30); keyButtons[action] = record
            let clear = NSButton(title: "清除", target: self, action: #selector(clearKey(_:)))
            clear.bezelStyle = .rounded; clear.tag = Int(action.rawValue)
            place(clear, x: 462, y: y - 2, w: 74, h: 30)
        }
        feedback.font = .systemFont(ofSize: 12); feedback.textColor = .secondaryLabelColor
        place(feedback, y: 205, h: 43)
        let divider = NSBox(); divider.boxType = .separator; place(divider, y: 192, h: 1)
        saveScreenshotButton.target = self; saveScreenshotButton.action = #selector(saveScreenshotChanged)
        place(saveScreenshotButton, y: 151, w: 380)
        visibilityButton.target = self; visibilityButton.action = #selector(visibilityChanged)
        place(visibilityButton, y: 114, w: 220)
        let recover = NSTextField(labelWithString: "隐藏后可从菜单栏图标恢复。")
        recover.font = .systemFont(ofSize: 11); recover.textColor = .secondaryLabelColor
        place(recover, x: 264, y: 114, w: 272)
        loginButton.target = self; loginButton.action = #selector(loginChanged)
        place(loginButton, y: 77, w: 220)
        let loginSettings = NSButton(title: "系统登录项…", target: self, action: #selector(openLoginSettings))
        loginSettings.bezelStyle = .rounded
        place(loginSettings, x: 386, y: 73, w: 150, h: 30)
        loginState.font = .systemFont(ofSize: 11); loginState.textColor = .secondaryLabelColor
        place(loginState, y: 39, h: 28)
    }
    private func refresh() {
        for (action, button) in keyButtons where !button.waiting {
            button.title = hotKeys.bindings[action]?.title ?? "设置快捷键…"
            button.toolTip = "点击后按组合键；Esc 取消"
        }
        saveScreenshotButton.state = (UserDefaults.standard.object(forKey: "saveScreenshots") as? Bool ?? false) ? .on : .off
        visibilityButton.state = getVisibility() ? .on : .off
        refreshLogin()
    }
    private func refreshLogin() {
        switch SMAppService.mainApp.status {
        case .enabled: loginButton.state = .on; loginState.stringValue = "已开启：下次登录时启动 ClawdSnip。"
        case .requiresApproval: loginButton.state = .mixed; loginState.stringValue = "等待系统批准：请到“系统登录项”允许 ClawdSnip。"
        case .notRegistered: loginButton.state = .off; loginState.stringValue = "未开启：可随时打开或关闭。"
        case .notFound: loginButton.state = .off; loginState.stringValue = "系统未识别此应用；请从已安装的应用程序位置重新打开。"
        @unknown default: loginButton.state = .off; loginState.stringValue = "无法确定系统登录项状态。"
        }
    }
    @objc private func recordKey(_ sender: ShortcutButton) {
        for button in keyButtons.values where button !== sender { button.cancel() }
        sender.begin()
        feedback.stringValue = "正在设置快捷键：请按组合键。Esc 取消，不支持仅 Shift 或裸按键。"
    }
    @objc private func clearKey(_ sender: NSButton) {
        for button in keyButtons.values { button.cancel() }
        if let action = AppAction(rawValue: UInt32(sender.tag)) { apply(action, key: nil) }
    }
    private func apply(_ action: AppAction, key: KeyCombination?) {
        do {
            try hotKeys.update(action, key: key)
            feedback.stringValue = "已保存“\(action.title)”：\(key?.title ?? "未设置")。"
        } catch {
            feedback.stringValue = error.localizedDescription
            resumeKeys()
        }
        refresh()
    }
    private func resumeKeys() {
        do { try hotKeys.resume() }
        catch { feedback.stringValue = error.localizedDescription }
        refresh()
    }
    @objc private func saveScreenshotChanged() { UserDefaults.standard.set(saveScreenshotButton.state == .on, forKey: "saveScreenshots") }
    @objc private func visibilityChanged() { setVisibility(visibilityButton.state == .on); refresh() }
    @objc private func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
    @objc private func loginChanged() {
        let enable = loginButton.state == .on
        loginButton.isEnabled = false
        Task {
            do {
                if enable {
                    if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                    else { try SMAppService.mainApp.register() }
                } else { try await SMAppService.mainApp.unregister() }
            } catch { feedback.stringValue = "修改开机启动失败：\(error.localizedDescription)" }
            loginButton.isEnabled = true; refreshLogin()
        }
    }
    func windowDidResignKey(_ notification: Notification) { for button in keyButtons.values { button.cancel() } }
    func windowWillClose(_ notification: Notification) { for button in keyButtons.values { button.cancel() } }
    func windowDidBecomeKey(_ notification: Notification) { refresh() }
}
