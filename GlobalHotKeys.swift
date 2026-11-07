import Cocoa
import Carbon

@MainActor
final class GlobalHotKeys {
    private let defaults: UserDefaults
    private var handler: EventHandlerRef?
    private let signature: OSType = 0x43534E50 // CSNP
    private var transaction: ShortcutTransaction<EventHotKeyRef>
    private(set) var bindings: [AppAction: KeyCombination] = [:]
    private var suspended = false
    var onAction: ((AppAction) -> Void)?

    init(defaults: UserDefaults = .standard) throws {
        self.defaults = defaults
        transaction = ShortcutTransaction(register: { action, key in
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x43534E50, id: action.rawValue)
            let status = RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
            guard status == noErr, let reference else {
                throw RecordingProblem("快捷键 \(key.title) 无法注册，可能已被系统或其他应用占用（\(status)）。请选择其他组合。")
            }
            return reference
        }, unregister: { UnregisterEventHotKey($0) })
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard status == noErr, hotKey.signature == 0x43534E50, let action = AppAction(rawValue: hotKey.id) else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<GlobalHotKeys>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                if !manager.suspended { manager.onAction?(action) }
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw RecordingProblem("无法初始化全局快捷键（\(status)）。") }
    }
    func restore() throws {
        let stored = ShortcutRules.load(from: defaults)
        bindings = stored
        try transaction.replace(with: stored)
    }
    func update(_ action: AppAction, key: KeyCombination?) throws {
        var next = bindings; next[action] = key
        try transaction.replace(with: next)
        // Save only after all requested OS registrations succeeded.
        try ShortcutRules.save(next, to: defaults)
        bindings = next; suspended = false
    }
    func suspend() { suspended = true; transaction.clear() }
    func resume() throws { guard suspended else { return }; try transaction.replace(with: bindings); suspended = false }
    func shutdown() {
        transaction.clear()
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}
