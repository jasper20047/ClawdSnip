import Cocoa
import ScreenCaptureKit

@main struct MotionCapture {
 @MainActor static func main() async {
  do{try await run()}catch{fputs("FAIL: \(error.localizedDescription)\n",stderr);exit(1)}
 }
 @MainActor static func run() async throws {
  _=NSApplication.shared
  guard CGPreflightScreenCaptureAccess() else{throw RecordingProblem("Diagnostic process has no existing capture authorization")}
  var target:SCWindow?,selectedDisplay:SCDisplay?
  for _ in 0..<40 {
   let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
   if let window=content.windows.first(where:{$0.title == "ClawdSnip Motion Fixture"}),
      let display=content.displays.first(where:{$0.frame.contains(CGPoint(x:window.frame.midX,y:window.frame.midY))}){target=window;selectedDisplay=display;break}
   try await Task.sleep(nanoseconds:50_000_000)
  }
  guard let window=target,let display=selectedDisplay else{throw RecordingProblem("Dedicated motion fixture is not visible")}
  let area=window.frame.insetBy(dx:20,dy:45)
  let recorder=ScreenRecorder()
  var result:Result<URL?,Error>?
  recorder.onFinished={result=$0}
  let quality=RecordingQuality(rawValue:ProcessInfo.processInfo.environment["CLAWD_TEST_QUALITY"] ?? "") ?? .sd720
  let options=RecordingOptions(quality:quality,systemAudio:CommandLine.arguments.contains("--audio"),microphone:false)
  await recorder.begin(options:options,displayID:display.displayID,region:area,url:URL(fileURLWithPath:CommandLine.arguments[1]))
  let seconds=Double(ProcessInfo.processInfo.environment["CLAWD_TEST_SECONDS"] ?? "") ?? 5
  if result==nil{try await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000));recorder.stop()}
  for _ in 0..<1200 where result==nil {try await Task.sleep(nanoseconds:50_000_000)}
  guard let result else{throw RecordingProblem("Recording finalization timed out")}
  _=try result.get()
  print("Capture finished")
 }
}
