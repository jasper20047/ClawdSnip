import Cocoa
import ScreenCaptureKit

private final class LongPreviewImageView:NSImageView {override var isFlipped:Bool{true}}

private actor LongCaptureProcessor {
 private var stitcher=LongImageStitcher()
 private var observed:GrayRows?
 func observe(_ image:CGImage) throws -> (LongImageStitcher.Result?,Int,Int) {
  let current=try GrayRows(image:image)
  defer{observed=current}
  guard let previous=observed,previous.difference(from:current)<0.75 else{return(nil,stitcher.width,stitcher.height)}
  let result=try stitcher.accept(image)
  return(result,stitcher.width,stitcher.height)
 }
 func image() throws -> CGImage? {stitcher.height>0 ? try stitcher.renderAndRelease():nil}
}

@MainActor
final class LongScreenshotController:NSObject,NSWindowDelegate {
 private enum Phase {case idle,choosing,starting,collecting,rendering,preview,outputting}
 private var phase=Phase.idle
 private var id:UUID?
 private var settings:NSWindow?
 private var control:NSPanel?
 private var preview:NSWindow?
 private var image:CGImage?
 private var selector:RegionSelector?
 private var task:Task<Void,Never>?
 private var processor:LongCaptureProcessor?
 private var sourceApp:NSRunningApplication?
 private let screenChoice=NSPopUpButton()
 private var screens=[NSScreen]()
 private let status=NSTextField(labelWithString:"")
 private let saveChoice=NSButton(checkboxWithTitle:"保存到文件",target:nil,action:nil)
 private let pasteChoice=NSButton(checkboxWithTitle:"自动粘贴",target:nil,action:nil)
 private var exitPending=false
 let output:(CGImage,ScreenshotOutputOptions,Bool,@escaping(Bool)->Void)->Void
 var isBusy:Bool {phase != .idle}
 init(output:@escaping(CGImage,ScreenshotOutputOptions,Bool,@escaping(Bool)->Void)->Void) {
  self.output=output;super.init()
  for name in [NSWorkspace.screensDidSleepNotification,NSWorkspace.sessionDidResignActiveNotification] {
   NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(interrupted),name:name,object:nil)
  }
  NotificationCenter.default.addObserver(self,selector:#selector(interrupted),name:NSApplication.didChangeScreenParametersNotification,object:nil)
 }
 func handleShortcut(){if phase == .collecting{finish()}else if !isBusy{show()}}
 func show(){
  guard !isBusy else{if phase == .choosing && selector == nil{settings?.makeKeyAndOrderFront(nil)};preview?.makeKeyAndOrderFront(nil);control?.orderFrontRegardless();return}
  id=UUID();phase = .choosing
  let front=NSWorkspace.shared.frontmostApplication
  sourceApp=front?.processIdentifier == getpid() ? nil:front
  let window=NSWindow(contentRect:CGRect(x:0,y:0,width:500,height:230),styleMask:[.titled,.closable],backing:.buffered,defer:false)
  window.title="ClawdSnip · 长截图";window.isReleasedWhenClosed=false;window.delegate=self;window.center();settings=window
  let title=NSTextField(labelWithString:"手动向下滚动，自动拼成长图")
  title.font = .systemFont(ofSize:19,weight:.semibold);title.frame=CGRect(x:20,y:178,width:460,height:28)
  window.contentView!.addSubview(title)
  let hint=NSTextField(wrappingLabelWithString:"框选固定的内容区域，避开工具栏、固定页头和视频。\n缓慢向下滚动并稍停，完成后预览；Esc 可取消框选。")
  hint.frame=CGRect(x:20,y:116,width:460,height:50);window.contentView!.addSubview(hint)
  screens=NSScreen.screens;screenChoice.removeAllItems()
  screenChoice.addItems(withTitles:screens.enumerated().map{"屏幕 \($0.offset+1) · \($0.element.localizedName)"})
  screenChoice.frame=CGRect(x:20,y:76,width:460,height:28);window.contentView!.addSubview(screenChoice)
  let start=NSButton(title:"框选区域并开始",target:self,action:#selector(selectArea));start.bezelStyle = .rounded
  start.frame=CGRect(x:300,y:20,width:180,height:34);window.contentView!.addSubview(start)
  NSApp.activate(ignoringOtherApps:true);window.makeKeyAndOrderFront(nil)
 }
 @objc private func selectArea(){
  let index=screenChoice.indexOfSelectedItem
  guard phase == .choosing,screens.indices.contains(index),let token=id else{return}
  let screen=screens[index];settings?.orderOut(nil)
  let picker=RegionSelector();picker.prompt="拖动框选长截图内容 · Esc 取消";selector=picker
  picker.present(on:screen){[weak self] area in
   guard let self,self.id==token else{return};self.selector=nil
   guard let area else{self.cancelAll();return}
   self.phase = .starting
   self.task=Task{await self.start(screen:screen,area:area,token:token)}
  }
 }
 private func start(screen:NSScreen,area:CGRect,token:UUID) async {
  do{
   guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else{throw RecordingProblem("需要录屏权限。若开关已经打开，请退出应用，移除旧条目并重新添加当前版本后授权。")}
   // Keep an own window visible before enumeration so the application exclusion is present even with the pet hidden.
   makeControl()
   let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
   guard id==token,phase == .starting else{return}
   guard let number=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
         let display=content.displays.first(where:{$0.displayID==number.uint32Value}) else{throw RecordingProblem("选中的屏幕已断开。")}
   let ownApps=content.applications.filter{$0.processID==getpid()}
   guard !ownApps.isEmpty else{throw RecordingProblem("无法排除采集控制窗口，请重新开始长截图。") }
   let filter=SCContentFilter(display:display,excludingApplications:ownApps,exceptingWindows:[])
   guard CGRect(origin:.zero,size:filter.contentRect.size).contains(area) else{throw RecordingProblem("框选区域已失效，请重新选择。")}
   let config=SCStreamConfiguration();config.sourceRect=area
   config.width=Int(area.width*CGFloat(filter.pointPixelScale));config.height=Int(area.height*CGFloat(filter.pointPixelScale))
   guard config.width>=8,config.height>=64,config.height<=30000,config.width<=40_000_000/config.height else{throw RecordingProblem("区域太小或超出长截图上限，请重新框选。")}
   config.showsCursor=false;config.capturesAudio=false;config.captureMicrophone=false
   let worker=LongCaptureProcessor();processor=worker;phase = .collecting
   sourceApp?.activate(options:[])
   while id==token,phase == .collecting,!Task.isCancelled {
    let frame=try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
    guard id==token,phase == .collecting,!Task.isCancelled else{return}
    let (result,width,height)=try await worker.observe(frame)
    guard id==token,phase == .collecting,!Task.isCancelled else{return}
    let dimensions=height>0 ? "\(width) × \(height) 像素":"等待首张画面"
    switch result {
    case .added:status.stringValue="已采集 \(dimensions) · 继续缓慢下滚"
    case .duplicate:status.stringValue="\(dimensions) · 无新内容，可继续或完成"
    case .unmatched:status.stringValue="重叠不足 · 返回上次位置后缓慢下滚"
    case .reverse:status.stringValue="请向下滚动 · 已保留 \(dimensions)"
    case .limit:status.stringValue="已达长度上限 · 正在生成预览";finish();return
    case nil:status.stringValue="\(dimensions) · 等待画面稳定"
    }
    try await Task.sleep(nanoseconds:300_000_000)
   }
  }catch{
   guard id==token,!Task.isCancelled,phase == .starting || phase == .collecting else{return}
   showError(error.localizedDescription)
   finish()
  }
 }
 private func makeControl(){
  let panel=NSPanel(contentRect:CGRect(x:0,y:0,width:520,height:66),styleMask:[.titled,.nonactivatingPanel],backing:.buffered,defer:false)
  panel.title="ClawdSnip · 长截图采集";panel.isReleasedWhenClosed=false;panel.level = .floating
  panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];panel.center()
  status.stringValue="等待画面稳定 · 在目标区域缓慢向下滚动"
  status.font = .systemFont(ofSize:11);status.frame=CGRect(x:12,y:23,width:335,height:20)
  panel.contentView!.addSubview(status)
  for (title,action,x) in [("完成",#selector(finish),CGFloat(345)),("取消",#selector(cancel),CGFloat(430))] {
   let button=NSButton(title:title,target:self,action:action);button.bezelStyle = .rounded
   button.frame=CGRect(x:x,y:17,width:78,height:32);panel.contentView!.addSubview(button)
  }
  control=panel;panel.orderFrontRegardless()
 }
 @objc private func finish(){
  guard phase == .collecting || phase == .starting else{return}
  phase = .rendering;task?.cancel();task=nil
  guard let token=id else{return}
  let worker=processor
  Task{
   do{
    let result=try await worker?.image()
    guard id==token,phase == .rendering else{return}
    control?.close();control=nil;processor=nil
    guard let result else{let exit=exitPending;cancelAll();if exit{NSApp.reply(toApplicationShouldTerminate:true)};return}
    image=result;showPreview(result)
    if exitPending{askQuitForPreview()}
   }catch{
    guard id==token else{return}
    let exit=exitPending;showError(error.localizedDescription);cancelAll()
    if exit{NSApp.reply(toApplicationShouldTerminate:false)}
   }
  }
 }
 private func showPreview(_ image:CGImage){
  phase = .preview
  let height=min(740,NSScreen.main?.visibleFrame.height ?? 740)-40
  let window=NSWindow(contentRect:CGRect(x:0,y:0,width:620,height:height),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
  window.title="长截图预览 · \(image.width) × \(image.height)";window.minSize=NSSize(width:620,height:360);window.isReleasedWhenClosed=false;window.delegate=self;window.center();preview=window
  let scroll=NSScrollView(frame:CGRect(x:16,y:110,width:588,height:height-126));scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=false
  scroll.autoresizingMask=[.width,.height]
  let w=min(560,image.width),h=max(1,Int(Double(image.height)*Double(w)/Double(image.width)))
  if let context=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue){
   context.interpolationQuality = .medium;context.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
   if let thumbnail=context.makeImage(){
    let view=LongPreviewImageView(frame:CGRect(x:0,y:0,width:w,height:h));view.image=NSImage(cgImage:thumbnail,size:CGSize(width:w,height:h));view.imageScaling = .scaleNone;scroll.documentView=view
   }
  }
  window.contentView!.addSubview(scroll)
  let defaults=ScreenshotOutputOptions.saved();saveChoice.state=defaults.saveToFile ? .on:.off;pasteChoice.state=defaults.autoPaste ? .on:.off
  saveChoice.frame=CGRect(x:20,y:68,width:200,height:24);pasteChoice.frame=CGRect(x:230,y:68,width:200,height:24)
  window.contentView!.addSubview(saveChoice);window.contentView!.addSubview(pasteChoice)
  let use=NSButton(title:"使用这张图",target:self,action:#selector(useImage));use.bezelStyle = .rounded;use.frame=CGRect(x:440,y:20,width:160,height:34)
  let cancel=NSButton(title:"取消",target:self,action:#selector(cancel));cancel.bezelStyle = .rounded;cancel.frame=CGRect(x:340,y:20,width:90,height:34)
  window.contentView!.addSubview(use);window.contentView!.addSubview(cancel)
  NSApp.activate(ignoringOtherApps:true);window.makeKeyAndOrderFront(nil)
  if let document=scroll.documentView{document.scroll(.zero)}
 }
 @objc private func useImage(){submit(quitting:false)}
 private func submit(quitting:Bool){
  guard phase == .preview,let image else{return}
  phase = .outputting;preview?.orderOut(nil)
  let options=ScreenshotOutputOptions(saveToFile:quitting || saveChoice.state == .on,autoPaste:!quitting && pasteChoice.state == .on)
  output(image,options,quitting){[weak self] succeeded in
   guard let self else{return}
   let exit=self.exitPending
   if succeeded{self.cancelAll()}
   else{self.exitPending=false;self.phase = .preview;self.preview?.makeKeyAndOrderFront(nil)}
   if exit{DispatchQueue.main.async{NSApp.reply(toApplicationShouldTerminate:succeeded)}}
  }
 }
 @objc private func cancel(){cancelAll()}
 private func cancelAll(){
  id=nil;phase = .idle;task?.cancel();task=nil;processor=nil;image=nil;exitPending=false
  selector?.cancel();selector=nil
  settings?.close();settings=nil;control?.close();control=nil;preview?.close();preview=nil;sourceApp=nil
 }
 @objc private func interrupted(){
  if phase == .collecting || phase == .starting{finish()}
  else if phase == .choosing{cancelAll()}
 }
 func shouldTerminate()->NSApplication.TerminateReply{
  guard isBusy else{return .terminateNow}
  if phase == .choosing{cancelAll();return .terminateNow}
  exitPending=true
  if phase == .preview{DispatchQueue.main.async{[weak self] in self?.askQuitForPreview()}}
  else if phase == .collecting || phase == .starting{finish()}
  return .terminateLater
 }
 private func askQuitForPreview(){
  let alert=NSAlert();alert.messageText="是否保存当前长截图后退出？"
  alert.addButton(withTitle:"保存并退出");alert.addButton(withTitle:"丢弃并退出");alert.addButton(withTitle:"取消退出")
  switch alert.runModal(){
  case .alertFirstButtonReturn:submit(quitting:true)
  case .alertSecondButtonReturn:cancelAll();NSApp.reply(toApplicationShouldTerminate:true)
  default:exitPending=false;NSApp.reply(toApplicationShouldTerminate:false)
  }
 }
 private func showError(_ message:String){let alert=NSAlert();alert.messageText="长截图提示";alert.informativeText=message;NSApp.activate(ignoringOtherApps:true);alert.runModal()}
 func windowWillClose(_ notification:Notification){
  guard let closed=notification.object as? NSWindow else{return}
  if (closed === settings && phase == .choosing) || (closed === preview && phase == .preview){cancelAll()}
 }
}
