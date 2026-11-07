import Cocoa
import Carbon

@main struct SettingsTests {
    static func main() throws {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ description: String) {
            count += 1
            if !value() { fputs("FAIL: \(description)\n", stderr); exit(1) }
        }
        let first = KeyCombination(keyCode: 18, modifiers: UInt32(cmdKey | optionKey), keyLabel: "1")
        let second = KeyCombination(keyCode: 19, modifiers: UInt32(cmdKey | optionKey), keyLabel: "2")
        for modifiers in [UInt32(0), UInt32(shiftKey)] {
            do { try KeyCombination(keyCode: 0, modifiers: modifiers, keyLabel: "A").validate(); check(false, "unmodified key rejected") } catch { count += 1 }
        }
        try first.validate(); count += 1
        do { try ShortcutRules.validate([.region: first, .window: KeyCombination(keyCode: 18, modifiers: first.modifiers, keyLabel: "different layout")]); check(false, "duplicate physical key rejected regardless of label") } catch { count += 1 }
        try ShortcutRules.validate([.region: first, .window: second]); count += 1
        let defaults = UserDefaults(suiteName: "ClawdSnip-settings-test-\(UUID().uuidString)")!
        check(ShortcutRules.load(from: defaults).isEmpty, "no default global key takeover")
        try ShortcutRules.save([.region: first, .recording: second], to: defaults)
        check(ShortcutRules.load(from: defaults)[.region] == first, "shortcut persists")
        try ShortcutRules.save([:], to: defaults)
        check(ShortcutRules.load(from: defaults).isEmpty, "cleared shortcut stays cleared")
        check(AppAction.recording.recordingIntent(phase: .idle) == .showSettings, "idle recording shortcut opens settings")
        check(AppAction.recording.recordingIntent(phase: .recording) == .stop, "active recording shortcut stops")
        check(AppAction.recording.recordingIntent(phase: .preparing) == .stop, "preparation shortcut cancels")
        check(AppAction.recording.recordingIntent(phase: .saving) == .ignore, "saving shortcut cannot restart")
        var calls = [UInt32]()
        var registry = ShortcutTransaction<UInt32>(register: { _, combo in
            if combo.keyCode == 20 { throw RecordingProblem("occupied") }
            calls.append(combo.keyCode); return combo.keyCode
        }, unregister: { handle in calls.removeAll(where: { $0 == handle }) })
        // Transaction uses real registered-handle lifetime callbacks; no OS privileges needed.
        try registry.replace(with: [.region: first])
        do { try registry.replace(with: [.region: KeyCombination(keyCode: 20, modifiers: first.modifiers, keyLabel: "3")]); check(false, "conflict fails") } catch { count += 1 }
        check(registry.bindings[.region] == first, "previous configuration restored on conflict")
        check(registry.handles.count == 1, "previous binding re-registered")
        try registry.replace(with: [.region: second, .window: first])
        check(registry.bindings[.region] == second && registry.handles.count == 2, "batch replace supports swaps")
        registry.clear()
        check(registry.handles.isEmpty, "clear releases all registrations")
        print("PASS: \(count) shortcut validation, persistence, routing and rollback checks")
    }
}
