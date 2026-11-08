import Cocoa

final class MotionView:NSView {
 var tick=0
 override func draw(_ dirtyRect:NSRect){
  NSColor(calibratedHue:CGFloat(tick%100)/100,saturation:0.8,brightness:0.9,alpha:1).setFill();bounds.fill()
  NSColor.white.setFill();CGRect(x:CGFloat(tick*17%Int(bounds.width-150)),y:bounds.height/2,width:150,height:120).fill()
  NSString(string:"ClawdSnip motion test \(tick)").draw(at:NSPoint(x:40,y:50),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:38,weight:.bold),.foregroundColor:NSColor.black])
 }
}
let app=NSApplication.shared;app.setActivationPolicy(.regular)
let available=NSScreen.main!.visibleFrame
let window=NSWindow(contentRect:CGRect(x:available.minX+100,y:available.minY+100,width:min(900,available.width-200),height:min(600,available.height-200)),styleMask:[.titled,.closable],backing:.buffered,defer:false)
window.title="ClawdSnip Motion Fixture";window.level = .floating;window.isReleasedWhenClosed=false
let view=MotionView(frame:window.contentView!.bounds);view.autoresizingMask=[.width,.height];window.contentView=view
let timer=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true){_ in view.tick+=1;view.needsDisplay=true}
window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true);app.run()
