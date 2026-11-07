import Cocoa
import AVFoundation
import ScreenCaptureKit
import VideoToolbox

@MainActor
final class ScreenRecorder: NSObject, SCStreamDelegate, SCRecordingOutputDelegate {
    private(set) var lifecycle = RecordingLifecycle()
    private(set) var message = "准备录屏"
    private(set) var startedAt: Date?
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var sessionID: UUID?
    private var rawURL: URL?
    private var destination: URL?
    private var wantsAudio = false
    private var captureStarted = false
    private var finalizing = false
    private var failing = false
    private var streamWarning: String?
    var onChange: (() -> Void)?
    var onFinished: ((Result<URL?, Error>) -> Void)?
    var isBusy: Bool { lifecycle.isBusy }
    var isRecording: Bool { lifecycle.phase == .recording }

    func begin(options: RecordingOptions, displayID: CGDirectDisplayID, region: CGRect?, url: URL) async {
        guard lifecycle.prepare() else { return }
        let id = UUID()
        sessionID = id; destination = url; wantsAudio = options.systemAudio || options.microphone
        captureStarted = false; finalizing = false; streamWarning = nil; startedAt = nil
        message = "检查录屏权限…"; onChange?()
        do {
            guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                throw RecordingProblem("请在系统设置 → 隐私与安全性 → 屏幕与系统录音中允许 ClawdSnip，然后退出并重新打开应用。")
            }
            if options.microphone {
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                guard sessionID == id else { return }
                guard allowed else { throw RecordingProblem("麦克风权限未开启。可到系统设置允许，或关闭“录制麦克风”后重试。") }
            }
            guard sessionID == id else { return }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard sessionID == id else { return }
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecordingProblem("选中的屏幕已断开，请重新选择。")
            }
            let ownApps = content.applications.filter { $0.processID == getpid() }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let full = CGRect(origin: .zero, size: filter.contentRect.size)
            let area = region ?? full
            guard area.width >= 2, area.height >= 2, full.contains(area) else {
                throw RecordingProblem("录制区域已失效，请重新框选。")
            }
            let config = try options.streamConfiguration(points: area.size, scale: CGFloat(filter.pointPixelScale))
            if region != nil { config.sourceRect = area }
            let recordingConfig = SCRecordingOutputConfiguration()
            recordingConfig.outputFileType = .mp4
            let codec: AVVideoCodecType = max(config.width, config.height) > 4096 ? .hevc : .h264
            guard recordingConfig.availableVideoCodecTypes.contains(codec) else {
                throw RecordingProblem("当前设备不支持这个分辨率的编码，请选择 1080p 或 1440p。")
            }
            var encoder: VTCompressionSession?
            let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: Int32(config.width), height: Int32(config.height), codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264, encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &encoder)
            if let encoder { VTCompressionSessionInvalidate(encoder) }
            guard status == noErr else { throw RecordingProblem("无法编码 \(config.width) × \(config.height) 像素，请改选较低清晰度。") }
            let directory = url.deletingLastPathComponent()
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
            if let free = attributes[.systemFreeSize] as? NSNumber, free.int64Value < 200_000_000 {
                throw RecordingProblem("保存位置可用空间不足 200 MB，请清理磁盘或更换保存位置。")
            }
            guard !FileManager.default.fileExists(atPath: url.path) else { throw RecordingProblem("文件已存在，请选择新的文件名。") }
            let raw = directory.appendingPathComponent(".ClawdSnip-capture-\(id.uuidString).mp4")
            recordingConfig.outputURL = raw
            recordingConfig.videoCodecType = codec
            rawURL = raw
            for second in (1...3).reversed() {
                guard sessionID == id else { return }
                message = "\(second) 秒后开始 · \(config.width) × \(config.height)"; onChange?()
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard sessionID == id else { return }
            let capture = SCStream(filter: filter, configuration: config, delegate: self)
            let recording = SCRecordingOutput(configuration: recordingConfig, delegate: self)
            stream = capture; output = recording
            try capture.addRecordingOutput(recording)
            guard lifecycle.startRecording() else { return }
            message = "正在启动录制…"; onChange?()
            try await capture.startCapture()
            guard sessionID == id else { return }
            captureStarted = true
            if lifecycle.phase == .saving { try await capture.stopCapture() }
        } catch {
            guard sessionID == id else { return }
            fail(error)
        }
    }

    func stop() {
        guard !failing else { return }
        if lifecycle.phase == .preparing {
            sessionID = nil; lifecycle.cancelPreparation(); message = "已取消录制"
            rawURL = nil; destination = nil; onChange?(); onFinished?(.success(nil))
            return
        }
        guard lifecycle.stop() else { return }
        message = "正在保存，请稍候…"; onChange?()
        guard captureStarted, let stream else { return } // begin() serializes stop after startCapture completes.
        let id = sessionID
        Task {
            do { try await stream.stopCapture() }
            catch { if self.sessionID == id { self.fail(error) } }
        }
    }

    private func fail(_ error: Error) {
        guard isBusy, !failing else { return }
        failing = true
        _ = lifecycle.beginFailureCleanup()
        message = "正在结束录制，请稍候…"; onChange?()
        let previous = stream
        let path = rawURL
        let id = sessionID
        Task {
            if let previous { try? await previous.stopCapture() }
            guard sessionID == id else { return }
            clear()
            var text = error.localizedDescription
            if let path, FileManager.default.fileExists(atPath: path.path) {
                text += "\n原始录像已保留：\(path.path)"
            }
            onFinished?(.failure(RecordingProblem(text)))
        }
    }

    private func clear() {
        sessionID = nil; stream = nil; output = nil; captureStarted = false; failing = false
        lifecycle.finish(); startedAt = nil; onChange?()
    }

    private func finishFile(_ recordingOutput: SCRecordingOutput) async {
        guard output === recordingOutput, !finalizing, !failing, let raw = rawURL, let target = destination else { return }
        finalizing = true
        _ = lifecycle.stop()
        message = "正在整理音轨并保存…"; onChange?()
        do {
            try await RecordingFile.finish(raw: raw, destination: target, expectAudio: wantsAudio)
            guard output === recordingOutput else { return }
            let warning = streamWarning
            clear()
            if let warning {
                onFinished?(.failure(RecordingProblem("录制中断：\(warning)\n已保存可用片段：\(target.path)")))
            } else { onFinished?(.success(target)) }
        } catch { if output === recordingOutput { fail(error) } }
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard self.output === recordingOutput, self.lifecycle.phase == .recording else { return }
            self.startedAt = Date(); self.message = "正在录制"; self.onChange?()
        }
    }
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in await self.finishFile(recordingOutput) }
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            guard self.output === recordingOutput else { return }; self.fail(error)
        }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in
            guard self.stream === stream else { return }
            self.streamWarning = error.localizedDescription
            // The system has already stopped this stream. Wait for output finalization.
            _ = self.lifecycle.stop()
            self.message = "录制已中断，正在保存可用片段…"
            self.onChange?()
        }
    }
}
