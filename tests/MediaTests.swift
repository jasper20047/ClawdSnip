import Cocoa
import AVFoundation

@main struct MediaTests {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let videoURL = root.appendingPathComponent("video.mov")
        let fixture = root.appendingPathComponent("two-tracks.mov")
        let output = root.appendingPathComponent("final.mp4")
        let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240])
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<60 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pixels.pixelBufferPool!, &buffer)
            CVPixelBufferLockBaseAddress(buffer!, [])
            memset(CVPixelBufferGetBaseAddress(buffer!)!, Int32(frame * 3), CVPixelBufferGetDataSize(buffer!))
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            guard pixels.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error! }
        }
        input.markAsFinished()
        await writer.finishWriting()
        let composition = AVMutableComposition()
        let video = AVURLAsset(url: videoURL)
        let vtrack = try await video.loadTracks(withMediaType: .video)[0]
        let length = CMTime(seconds: 1.9, preferredTimescale: 600)
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: vtrack, at: .zero)
        for name in ["440.wav", "880.wav"] {
            let asset = AVURLAsset(url: root.appendingPathComponent(name))
            let audio = try await asset.loadTracks(withMediaType: .audio)[0]
            try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: audio, at: .zero)
        }
        let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        try await export.export(to: fixture, as: .mov)
        try await RecordingFile.finish(raw: fixture, destination: output, expectAudio: true)
        let asset = AVURLAsset(url: output)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        guard audios.count == 1 else { fatalError("two inputs must become one playable audio track") }
        let size = try await asset.loadTracks(withMediaType: .video)[0].load(.naturalSize)
        guard size == CGSize(width: 320, height: 240) else { fatalError("dimensions changed") }
        let reader = try AVAssetReader(asset: asset)
        let audioReader = AVAssetReaderTrackOutput(track: audios[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1])
        reader.add(audioReader); reader.startReading()
        var samples = [Float]()
        while let sample = audioReader.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(sample) {
            let bytes = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: bytes / 4)
            let result = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!) }
            guard result == noErr else { fatalError("read PCM failed") }
            samples += values
        }
        guard samples.count > 48000 else { fatalError("audio too short") }
        for frequency in [440.0, 880.0] {
            var re = 0.0, im = 0.0
            for i in 4800..<48000 {
                let phase = 2 * Double.pi * frequency * Double(i) / 48000
                re += Double(samples[i]) * cos(phase); im += Double(samples[i]) * sin(phase)
            }
            guard hypot(re, im) / 43200 > 0.03 else { fatalError("missing \(frequency) Hz source") }
        }
        // Existing destination must never be overwritten, even if created after save dialog.
        let protected = root.appendingPathComponent("protected.mp4")
        try Data("keep".utf8).write(to: protected)
        do { try await RecordingFile.finish(raw: output, destination: protected, expectAudio: true); fatalError("overwrote existing file") }
        catch { guard try Data(contentsOf: protected) == Data("keep".utf8) else { fatalError("destination corrupted") } }
        print("PASS: video size/duration, two-source audio mixing (440 + 880 Hz), safe no-overwrite export")
    }
}
