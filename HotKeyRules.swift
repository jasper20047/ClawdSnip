import Cocoa
import Carbon

enum AppAction: UInt32, Codable, CaseIterable {
    case region = 1, window, recording, quit, togglePet
    case longScreenshot = 6
    var title: String {
        switch self {
        case .longScreenshot: return "长截图 / 完成采集"
        case .region: return "框选截图"
        case .window: return "窗口截图"
        case .recording: return "录屏 / 停止录屏"
        case .quit: return "退出应用"
        case .togglePet: return "显示 / 隐藏宠物"
        }
    }
    enum RecordingIntent { case showSettings, stop, ignore }
    func recordingIntent(phase: RecordingLifecycle.Phase) -> RecordingIntent {
        switch phase { case .idle: return .showSettings; case .preparing, .recording: return .stop; case .saving: return .ignore }
    }
}

struct KeyCombination: Codable, Hashable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers }
    func hash(into hasher: inout Hasher) { hasher.combine(keyCode); hasher.combine(modifiers) }
    func validate() throws {
        let allowed = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        guard modifiers & UInt32(cmdKey | optionKey | controlKey) != 0,
              modifiers & ~allowed == 0, keyCode <= 127, !(54...63).contains(keyCode) else {
            throw RecordingProblem("请按住 ⌘、⌥ 或 ⌃ 中至少一个键，再按字母、数字或功能键；不支持单独按键或只加 Shift。")
        }
    }
    var title: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + keyLabel
    }
    static func from(_ event: NSEvent) throws -> Self {
        var modifiers: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        let names: [UInt16: String] = [36:"↩",48:"⇥",49:"Space",51:"⌫",53:"Esc",76:"⌤",117:"⌦",123:"←",124:"→",125:"↓",126:"↑",115:"Home",119:"End",116:"PageUp",121:"PageDown",122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12"]
        if flags.contains(.function), names[event.keyCode] == nil {
            throw RecordingProblem("这个组合包含不支持的 Fn / 地球键，请换一个组合。")
        }
        let label = names[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased() ?? "Key\(event.keyCode)"
        let result = Self(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
        try result.validate()
        return result
    }
}

enum ShortcutRules {
    private struct Entry: Codable { let action: AppAction; let key: KeyCombination }
    static func validate(_ bindings: [AppAction: KeyCombination]) throws {
        var seen = [KeyCombination: AppAction]()
        for action in AppAction.allCases {
            guard let key = bindings[action] else { continue }
            try key.validate()
            if let other = seen[key] { throw RecordingProblem("“\(action.title)”与“\(other.title)”使用了相同的快捷键。") }
            seen[key] = action
        }
    }
    static func load(from defaults: UserDefaults = .standard) -> [AppAction: KeyCombination] {
        guard let data = defaults.data(forKey: "globalShortcuts"), let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [:] }
        var result = [AppAction: KeyCombination]()
        for entry in entries { result[entry.action] = entry.key }
        return (try? validate(result)) != nil ? result : [:]
    }
    static func save(_ bindings: [AppAction: KeyCombination], to defaults: UserDefaults = .standard) throws {
        try validate(bindings)
        let entries = AppAction.allCases.compactMap { action in bindings[action].map { Entry(action: action, key: $0) } }
        defaults.set(try JSONEncoder().encode(entries), forKey: "globalShortcuts")
    }
}

struct ShortcutTransaction<Handle> {
    private(set) var bindings = [AppAction: KeyCombination]()
    private(set) var handles = [AppAction: Handle]()
    let register: (AppAction, KeyCombination) throws -> Handle
    let unregister: (Handle) -> Void
    mutating func clear() {
        for handle in handles.values { unregister(handle) }
        handles = [:]
    }
    mutating func replace(with new: [AppAction: KeyCombination]) throws {
        try ShortcutRules.validate(new)
        let previous = bindings
        clear()
        do {
            for action in AppAction.allCases {
                if let key = new[action] { handles[action] = try register(action, key) }
            }
            bindings = new
        } catch {
            clear()
            var restoreFailed = false
            for action in AppAction.allCases {
                if let key = previous[action] {
                    do { handles[action] = try register(action, key) } catch { restoreFailed = true }
                }
            }
            bindings = previous
            if restoreFailed { throw RecordingProblem("快捷键冲突，部分旧快捷键也未能恢复。请重新设置。\n\(error.localizedDescription)") }
            throw error
        }
    }
}
