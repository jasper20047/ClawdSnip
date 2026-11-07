import Cocoa
import ScreenCaptureKit

struct RecordingProblem: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

enum RecordingQuality: String, CaseIterable {
    case sd720, hd1080, qhd1440, native
    var title: String {
        switch self {
        case .sd720: return "标清 · 720p"
        case .hd1080: return "高清 · 1080p"
        case .qhd1440: return "超清 · 1440p"
        case .native: return "原始分辨率"
        }
    }
    func outputSize(points: CGSize, scale: CGFloat) throws -> (width: Int, height: Int) {
        let w = points.width * scale, h = points.height * scale
        guard w.isFinite, h.isFinite, w >= 2, h >= 2, w <= 65536, h <= 65536 else {
            throw RecordingProblem("录制区域无效，请重新选择至少 2 × 2 像素的区域。")
        }
        let short: CGFloat
        switch self { case .sd720: short = 720; case .hd1080: short = 1080; case .qhd1440: short = 1440; case .native: short = max(w, h) }
        let factor = self == .native ? 1 : min(1, short / min(w, h), (short * 16 / 9) / max(w, h))
        return (max(2, Int(floor(w * factor / 2)) * 2), max(2, Int(floor(h * factor / 2)) * 2))
    }
}

struct RecordingOptions {
    var quality: RecordingQuality
    var systemAudio: Bool
    var microphone: Bool
    static func saved(in defaults: UserDefaults = .standard) -> Self {
        Self(quality: RecordingQuality(rawValue: defaults.string(forKey: "recordingQuality") ?? "") ?? .hd1080,
             systemAudio: defaults.object(forKey: "recordingSystemAudio") as? Bool ?? true,
             microphone: defaults.object(forKey: "recordingMicrophone") as? Bool ?? false)
    }
    func save(in defaults: UserDefaults = .standard) {
        defaults.set(quality.rawValue, forKey: "recordingQuality")
        defaults.set(systemAudio, forKey: "recordingSystemAudio")
        defaults.set(microphone, forKey: "recordingMicrophone")
    }
    func streamConfiguration(points: CGSize, scale: CGFloat) throws -> SCStreamConfiguration {
        let size = try quality.outputSize(points: points, scale: scale)
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.showsCursor = true
        config.capturesAudio = systemAudio
        config.captureMicrophone = microphone
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        return config
    }
}

struct RecordingLifecycle {
    enum Phase { case idle, preparing, recording, saving }
    private(set) var phase: Phase = .idle
    var isBusy: Bool { phase != .idle }
    @discardableResult mutating func prepare() -> Bool {
        guard phase == .idle else { return false }; phase = .preparing; return true
    }
    @discardableResult mutating func startRecording() -> Bool {
        guard phase == .preparing else { return false }; phase = .recording; return true
    }
    @discardableResult mutating func stop() -> Bool {
        guard phase == .recording else { return false }; phase = .saving; return true
    }
    @discardableResult mutating func beginFailureCleanup() -> Bool {
        guard isBusy else { return false }; phase = .saving; return true
    }
    mutating func cancelPreparation() { if phase == .preparing { phase = .idle } }
    mutating func finish() { phase = .idle }
}
