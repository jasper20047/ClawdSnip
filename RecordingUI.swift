import Cocoa

@MainActor
final class RecordingUI: NSObject, NSWindowDelegate {
    let recorder = ScreenRecorder()
    private var window: NSWindow?
    private let screenChoice = NSPopUpButton()
    private let rangeChoice = NSPopUpButton()
    private let qualityChoice = NSPopUpButton()
    private let systemSound = NSButton(checkboxWithTitle: "录制电脑声音", target: nil, action: nil)
    private let microphone = NSButton(checkboxWithTitle: "录制麦克风", target: nil, action: nil)
    private let sizeLabel = NSTextField(labelWithString: "")
    private let startButton = NSButton(title: "开始录制…", target: nil, action: nil)
    private let regionButton = NSButton(title: "框选区域…", target: nil, action: nil)
    private var screens: [NSScreen] = []
    private var region: CGRect?
    private var selector: RegionSelector?
    private var selectingSave = false
    private var statusItem: NSStatusItem?
    private var controls: NSPanel?
    private let timeLabel = NSTextField(labelWithString: "")
    private let stopButton = NSButton(title: "停止并保存", target: nil, action: nil)
    private var timer: Timer?
    private var quitting = false
    var isBusy: Bool { recorder.isBusy || selectingSave || selector != nil }

    override init() {
        super.init()
        recorder.onChange = { [weak self] in self?.updateStatus() }
        recorder.onFinished = { [weak self] result in self?.finished(result) }
        let notifications = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            notifications.addObserver(self, selector: #selector(interrupted), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func handleShortcut() {
        switch AppAction.recording.recordingIntent(phase: recorder.lifecycle.phase) {
        case .showSettings: show()
        case .stop: recorder.stop()
        case .ignore: break
        }
    }

    func show() {
        if recorder.isBusy { controls?.orderFrontRegardless(); return }
        if window == nil { makeSettings() }
        guard !selectingSave, selector == nil else { return }
        screens = NSScreen.screens
        screenChoice.removeAllItems()
        screenChoice.addItems(withTitles: screens.enumerated().map { "屏幕 \($0.offset + 1) · \($0.element.localizedName)" })
        region = nil; rangeChoice.selectItem(at: 0)
        updateDimensions()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeSettings() {
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 472), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "ClawdSnip · 录屏"; w.isReleasedWhenClosed = false; w.delegate = self
        w.center(); window = w
        let root = w.contentView!
        func label(_ text: String, _ y: CGFloat, size: CGFloat = 13) {
            let field = NSTextField(labelWithString: text)
            field.font = .systemFont(ofSize: size, weight: size > 16 ? .semibold : .regular)
            field.frame = CGRect(x: 24, y: y, width: 432, height: 24); root.addSubview(field)
        }
        label("录下画面，也录下你想要的声音", 419, size: 20)
        label("声音可独立选择；关闭麦克风也能录电脑内部声音。", 387, size: 12)
        func place(_ view: NSView, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat = 28) {
            view.frame = CGRect(x: x, y: y, width: width, height: height); root.addSubview(view)
        }
        label("录制屏幕", 342); place(screenChoice, 132, 342, 322)
        screenChoice.target = self; screenChoice.action = #selector(screenChanged)
        label("录制范围", 298)
        rangeChoice.addItems(withTitles: ["整个屏幕", "框选区域"])
        rangeChoice.target = self; rangeChoice.action = #selector(rangeChanged)
        place(rangeChoice, 132, 298, 165)
        regionButton.target = self; regionButton.action = #selector(selectRegion)
        place(regionButton, 306, 298, 148)
        label("清晰度", 254)
        qualityChoice.addItems(withTitles: RecordingQuality.allCases.map(\.title))
        qualityChoice.target = self; qualityChoice.action = #selector(optionsChanged)
        place(qualityChoice, 132, 254, 322)
        sizeLabel.textColor = .secondaryLabelColor; sizeLabel.font = .systemFont(ofSize: 12)
        place(sizeLabel, 132, 225, 322, 22)
        let saved = RecordingOptions.saved()
        qualityChoice.selectItem(at: RecordingQuality.allCases.firstIndex(of: saved.quality) ?? 1)
        systemSound.state = saved.systemAudio ? .on : .off
        microphone.state = saved.microphone ? .on : .off
        for button in [systemSound, microphone] { button.target = self; button.action = #selector(optionsChanged) }
        place(systemSound, 24, 178, 210); place(microphone, 250, 178, 210)
        label("仅录电脑声音：勾选左侧，关闭右侧麦克风。", 142, size: 12)
        label("MP4 · 30 帧/秒 · 开始前选择保存位置 · 倒计时 3 秒", 110, size: 12)
        startButton.target = self; startButton.action = #selector(start)
        startButton.bezelStyle = .rounded; startButton.keyEquivalent = "\r"
        place(startButton, 304, 35, 150, 36)
        let cancel = NSButton(title: "关闭", target: self, action: #selector(closeSettings))
        cancel.bezelStyle = .rounded; cancel.keyEquivalent = "\u{1b}"
        place(cancel, 198, 35, 96, 36)
    }

    private var selectedScreen: NSScreen? {
        let index = screenChoice.indexOfSelectedItem
        return screens.indices.contains(index) ? screens[index] : nil
    }
    private var options: RecordingOptions {
        RecordingOptions(quality: RecordingQuality.allCases[max(0, qualityChoice.indexOfSelectedItem)], systemAudio: systemSound.state == .on, microphone: microphone.state == .on)
    }
    @objc private func closeSettings() { window?.close() }
    @objc private func screenChanged() { region = nil; updateDimensions() }
    @objc private func optionsChanged() { options.save(); updateDimensions() }
    @objc private func rangeChanged() {
        updateDimensions()
        if rangeChoice.indexOfSelectedItem == 1, region == nil { selectRegion() }
    }
    private func updateDimensions() {
        regionButton.isEnabled = rangeChoice.indexOfSelectedItem == 1
        guard let screen = selectedScreen else { startButton.isEnabled = false; return }
        let needRegion = rangeChoice.indexOfSelectedItem == 1
        let points = needRegion ? region?.size : screen.frame.size
        guard let points, let pixels = try? options.quality.outputSize(points: points, scale: screen.backingScaleFactor) else {
            sizeLabel.stringValue = "请先框选录制区域"; startButton.isEnabled = false; return
        }
        sizeLabel.stringValue = "输出 \(pixels.width) × \(pixels.height) 像素 · 保持比例"
        startButton.isEnabled = !isBusy
    }
    @objc private func selectRegion() {
        guard !isBusy, let screen = selectedScreen else { return }
        rangeChoice.selectItem(at: 1)
        window?.orderOut(nil)
        let selection = RegionSelector(); selector = selection
        selection.present(on: screen) { [weak self] area in
            guard let self else { return }
            self.selector = nil
            if let area { self.region = area }
            else if self.region == nil { self.rangeChoice.selectItem(at: 0) }
            self.updateDimensions()
            self.window?.makeKeyAndOrderFront(nil)
        }
    }
    @objc private func start() {
        guard !isBusy, let screen = selectedScreen,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        let selectedRegion = rangeChoice.indexOfSelectedItem == 1 ? region : nil
        if rangeChoice.indexOfSelectedItem == 1 && selectedRegion == nil { selectRegion(); return }
        let chosen = options
        chosen.save()
        let save = NSSavePanel()
        save.allowedContentTypes = [.mpeg4Movie]
        save.canCreateDirectories = true
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        let directory = movies.appendingPathComponent("ClawdSnip", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        save.directoryURL = directory
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        save.nameFieldStringValue = "ClawdSnip \(formatter.string(from: Date())).mp4"
        save.title = "选择录像保存位置"; save.prompt = "倒计时并开始"
        selectingSave = true; updateDimensions()
        save.beginSheetModal(for: window!) { [weak self] response in
            guard let self else { return }
            self.selectingSave = false; self.updateDimensions()
            guard response == .OK, let url = save.url else { return }
            guard !FileManager.default.fileExists(atPath: url.path) else {
                self.alert("请选择新文件名", "为保护已有录像，请选择一个不存在的文件名。"); return
            }
            self.window?.orderOut(nil)
            Task { await self.recorder.begin(options: chosen, displayID: id.uint32Value, region: selectedRegion, url: url) }
        }
    }

    private func makeControls() {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 390, height: 62), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "ClawdSnip · 录制控制"
        panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        timeLabel.frame = CGRect(x: 14, y: 20, width: 232, height: 22)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        panel.contentView!.addSubview(timeLabel)
        stopButton.frame = CGRect(x: 250, y: 15, width: 126, height: 32)
        stopButton.bezelStyle = .rounded; stopButton.target = self; stopButton.action = #selector(stop)
        panel.contentView!.addSubview(stopButton)
        panel.center(); controls = panel
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.addItem(withTitle: "显示录制控制", action: #selector(showControls), keyEquivalent: "").target = self
        menu.addItem(withTitle: "停止并保存", action: #selector(stop), keyEquivalent: "").target = self
        item.menu = menu; statusItem = item
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatus() }
        }
    }
    private func updateStatus() {
        guard recorder.isBusy else {
            timer?.invalidate(); timer = nil
            controls?.close(); controls = nil
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }; statusItem = nil
            return
        }
        if controls == nil { makeControls() }
        let elapsed = Int(recorder.startedAt.map { Date().timeIntervalSince($0) } ?? 0)
        let clock = String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
        let recording = recorder.isRecording && recorder.startedAt != nil
        timeLabel.stringValue = recording ? "🔴 正在录制  \(clock)" : recorder.message
        statusItem?.button?.title = recording ? "● \(clock)" : "◉ 录屏"
        statusItem?.button?.contentTintColor = recording ? .systemRed : nil
        stopButton.title = recorder.lifecycle.phase == .preparing ? "取消" : "停止并保存"
        stopButton.isEnabled = recorder.lifecycle.phase != .saving
        controls?.orderFrontRegardless()
    }
    @objc private func showControls() { controls?.orderFrontRegardless() }
    @objc private func stop() { recorder.stop() }
    @objc private func interrupted() { selector?.cancel(); recorder.stop() }
    @objc private func displaysChanged() {
        selector?.cancel()
        if recorder.isBusy { recorder.stop() }
        else if window?.isVisible == true { show() }
    }
    func shouldTerminate() -> NSApplication.TerminateReply {
        guard recorder.isBusy else { selector?.cancel(); return .terminateNow }
        quitting = true; recorder.stop(); return .terminateLater
    }
    private func finished(_ result: Result<URL?, Error>) {
        if quitting {
            if case .failure(let error) = result {
                quitting = false
                alert("录像保存遇到问题", error.localizedDescription)
                NSApp.reply(toApplicationShouldTerminate: false)
            } else {
                DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
            }
            return
        }
        switch result {
        case .success(let url):
            guard let url else { return }
            let alert = NSAlert(); alert.messageText = "录像已保存"
            alert.informativeText = url.path
            alert.addButton(withTitle: "在 Finder 中显示"); alert.addButton(withTitle: "完成")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .failure(let error): alert("录屏未正常完成", error.localizedDescription)
        }
    }
    private func alert(_ title: String, _ text: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = text
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
}
