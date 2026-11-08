import Cocoa
let claudeBundleID="local.ClawdSnip.NoExternalAppForTest"
func postCommandV(){fatalError("Clipboard-only test must not paste")}

@main struct ClipboardTests {
 @MainActor static func main() async throws {
  _=NSApplication.shared
  let clipboard=NSPasteboard.withUniqueName()
  defer{clipboard.releaseGlobally()}
  let context=CGContext(data:nil,width:120,height:80,bitsPerComponent:8,bytesPerRow:480,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(CGColor(gray:0.4,alpha:1));context.fill(CGRect(x:0,y:0,width:120,height:80))
  let image=context.makeImage()!,png=try ScreenshotFile.pngData(from:context.makeImage()!)
  let output=ScreenshotOutputController(pasteboard:clipboard)
  var succeeded=false
  output.deliver(image,png:png,options:ScreenshotOutputOptions(saveToFile:false,autoPaste:false)){succeeded=$0}
  for _ in 0..<500 where output.isBusy {try await Task.sleep(nanoseconds:1_000_000)}
  guard succeeded,!output.isBusy,clipboard.data(forType:.png)==png else{fatalError("clipboard-only output did not complete correctly")}
  print("PASS: clipboard-only output completes with original PNG and no paste or save dialog")
 }
}
