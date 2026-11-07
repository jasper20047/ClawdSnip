import Cocoa

@MainActor
final class AppStatusMenu: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    var onAction: ((AppAction) -> Void)?
    var onSettings: (() -> Void)?
    var isPetVisible: (() -> Bool)?
    var shortcuts: (() -> [AppAction: KeyCombination])?
    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        let image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "ClawdSnip")
        image?.isTemplate = true; item.button?.image = image
        item.button?.toolTip = "ClawdSnip · 截图、录屏与设置"
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let visible = isPetVisible?() ?? true
        let toggle = menu.addItem(withTitle: visible ? "隐藏桌面宠物" : "显示桌面宠物", action: #selector(pick(_:)), keyEquivalent: "")
        toggle.tag = Int(AppAction.togglePet.rawValue); toggle.target = self
        menu.addItem(.separator())
        for action in [AppAction.region, .window, .recording] {
            let suffix = shortcuts?()[action].map { "    \($0.title)" } ?? ""
            let entry = menu.addItem(withTitle: action.title + suffix, action: #selector(pick(_:)), keyEquivalent: "")
            entry.tag = Int(action.rawValue); entry.target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(settings), keyEquivalent: "").target = self
        let quit = menu.addItem(withTitle: "退出 ClawdSnip", action: #selector(pick(_:)), keyEquivalent: "")
        quit.tag = Int(AppAction.quit.rawValue); quit.target = self
    }
    @objc private func pick(_ sender: NSMenuItem) {
        if let action = AppAction(rawValue: UInt32(sender.tag)) { onAction?(action) }
    }
    @objc private func settings() { onSettings?() }
}
