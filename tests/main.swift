import Cocoa
import ScreenCaptureKit

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !condition() { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
let fixtures: [(RecordingQuality, CGSize, CGFloat, Int, Int)] = [
    (.hd1080, CGSize(width: 1512, height: 982), 2, 1662, 1080),
    (.sd720, CGSize(width: 1920, height: 1080), 1, 1280, 720),
    (.qhd1440, CGSize(width: 1080, height: 1920), 2, 1440, 2560),
    (.hd1080, CGSize(width: 3440, height: 1440), 1, 1920, 802),
    (.hd1080, CGSize(width: 601, height: 301), 1, 600, 300),
    (.native, CGSize(width: 1512, height: 982), 2, 3024, 1964)
]
for (quality, points, scale, w, h) in fixtures {
    let size = try quality.outputSize(points: points, scale: scale)
    check(size.width == w && size.height == h, "size \(quality): got \(size), expected \(w)x\(h)")
}
for size in [CGSize.zero, CGSize(width: -1, height: 20), CGSize(width: CGFloat.infinity, height: 20)] {
    do { _ = try RecordingQuality.native.outputSize(points: size, scale: 2); check(false, "reject invalid size") } catch { checks += 1 }
}
for system in [false, true] {
    for mic in [false, true] {
        let options = RecordingOptions(quality: .hd1080, systemAudio: system, microphone: mic)
        let config = try options.streamConfiguration(points: CGSize(width: 1920, height: 1080), scale: 1)
        check(config.capturesAudio == system, "system audio independent from microphone")
        check(config.captureMicrophone == mic, "microphone independent from system audio")
        check(config.width == 1920 && config.height == 1080, "real stream dimensions")
        check(config.minimumFrameInterval.seconds >= 1.0 / 30, "30 fps maximum")
    }
}
var state = RecordingLifecycle()
check(!state.startRecording(), "cannot record before preparation")
check(state.prepare(), "begin preparation")
check(!state.prepare(), "reject duplicate start")
check(state.startRecording(), "record after preparation")
check(!state.prepare(), "reject start while recording")
check(state.stop(), "stop records saving state")
check(state.phase == .saving && !state.prepare(), "must finish saving before restart")
state.finish()
check(state.prepare(), "restart after save")
state.cancelPreparation()
check(!state.startRecording() && state.phase == .idle, "cancel rejects late start")
check(state.prepare(), "prepare cleanup test")
check(state.beginFailureCleanup(), "error enters cleanup")
check(state.phase == .saving && !state.prepare(), "error cleanup stays busy until stream is closed")
check(!state.startRecording(), "late start rejected during error cleanup")
state.finish()
check(state.prepare(), "restart only after cleanup completes")
print("PASS: \(checks) recording configuration and lifecycle checks")
