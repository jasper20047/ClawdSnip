import Cocoa
import Carbon

@main struct HotKeyIntegration {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let firstName = "ClawdSnip-integration-\(UUID().uuidString)"
        let secondName = "ClawdSnip-integration-\(UUID().uuidString)"
        let firstDefaults = UserDefaults(suiteName: firstName)!
        let secondDefaults = UserDefaults(suiteName: secondName)!
        defer { firstDefaults.removePersistentDomain(forName: firstName); secondDefaults.removePersistentDomain(forName: secondName) }
        let first = try GlobalHotKeys(defaults: firstDefaults)
        let second = try GlobalHotKeys(defaults: secondDefaults)
        defer { first.shutdown(); second.shutdown() }
        let key = KeyCombination(keyCode: 79, modifiers: UInt32(cmdKey | controlKey | optionKey | shiftKey), keyLabel: "F18")
        try first.update(.togglePet, key: key)
        do { try second.update(.region, key: key); fatalError("exclusive conflict was accepted") }
        catch { guard ShortcutRules.load(from: secondDefaults).isEmpty else { fatalError("failed registration was saved") } }
        first.suspend()
        try second.update(.region, key: key)
        second.shutdown()
        try first.resume()
        guard first.bindings[.togglePet] == key else { fatalError("suspend/resume lost binding") }
        let settings = SettingsUI(hotKeys: first, getVisibility: { true }, setVisibility: { _ in })
        settings.show()
        let window = NSApp.windows.first(where: { $0.title == "ClawdSnip · 设置" })!
        let capture = window.contentView!.subviews.compactMap { $0 as? NSButton }.first(where: { $0.title == key.title })!
        capture.performClick(nil)
        try second.update(.region, key: key) // The existing registration must be suspended during capture.
        try second.update(.region, key: nil)
        settings.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: window))
        do { try second.update(.region, key: key); fatalError("focus loss left original hotkey suspended") }
        catch { /* original hotkey was restored after leaving settings */ }
        window.close()
        try first.update(.togglePet, key: nil)
        guard ShortcutRules.load(from: firstDefaults).isEmpty else { fatalError("clear did not persist") }
        print("PASS: real exclusive OS hotkey conflict, suspend/resume, settings focus-loss recovery and clear (isolated preferences)")
    }
}
