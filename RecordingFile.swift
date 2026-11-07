import Foundation
import AVFoundation

enum RecordingFile {
    /// Do not remove the capture until the playable result is successfully published.
    static func finish(raw: URL, destination: URL, expectAudio: Bool) async throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else {
            throw RecordingProblem("保存位置已有同名文件，原始录像保留在：\(raw.path)")
        }
        let asset = AVURLAsset(url: raw)
        let videos = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration)
        guard !videos.isEmpty, duration.seconds.isFinite, duration.seconds > 0 else {
            throw RecordingProblem("没有有效画面。请检查屏幕录制权限。原始文件：\(raw.path)")
        }
        let audios = try await asset.loadTracks(withMediaType: .audio)
        guard !expectAudio || !audios.isEmpty else {
            throw RecordingProblem("录像没有音轨，请检查录音权限。原始文件：\(raw.path)")
        }
        if audios.count <= 1 {
            try fm.moveItem(at: raw, to: destination)
            return
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = audios.map { track in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(0.7, at: .zero)
            return parameters
        }
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw RecordingProblem("无法合并音轨。原始文件：\(raw.path)")
        }
        let mixed = destination.deletingLastPathComponent().appendingPathComponent(".ClawdSnip-mix-\(UUID().uuidString).mp4")
        exporter.audioMix = mix
        exporter.shouldOptimizeForNetworkUse = true
        do { try await exporter.export(to: mixed, as: .mp4) }
        catch {
            try? fm.removeItem(at: mixed)
            throw RecordingProblem("音轨合并失败：\(error.localizedDescription)\n原始文件：\(raw.path)")
        }
        do { try fm.moveItem(at: mixed, to: destination) }
        catch { throw RecordingProblem("无法保存到所选位置：\(error.localizedDescription)\n合并后的录像：\(mixed.path)\n原始录像：\(raw.path)") }
        try? fm.removeItem(at: raw)
    }
}
