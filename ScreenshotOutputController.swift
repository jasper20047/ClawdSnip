import Cocoa
import ApplicationServices
import UniformTypeIdentifiers

@MainActor
final class ScreenshotOutputController {
 private let pasteboard:NSPasteboard
 init(pasteboard:NSPasteboard = .general){self.pasteboard=pasteboard}
 private var image:CGImage?
 private var data:Data?
 private var options=ScreenshotOutputOptions(saveToFile:false,autoPaste:true)
 private var claude:NSRunningApplication?
 private var completion:((Bool)->Void)?
 private var sessionID:UUID?
 private var saveID:UUID?
 private var savePanel:NSSavePanel?
 private var pasteTask:Task<Void,Never>?
 private var includeTIFF=true
 private var encoding=false,writing=false,quitDelivery=false,pendingQuit=false
 var onMessage:((String)->Void)?
 var isBusy:Bool {sessionID != nil}

 func deliver(_ image:CGImage,png:Data?=nil,options:ScreenshotOutputOptions,claude:NSRunningApplication?=nil,includeTIFF:Bool=true,quitting:Bool=false,completion:@escaping(Bool)->Void) {
  guard !isBusy else{return}
  let id=UUID();sessionID=id;self.image=image;self.options=options;self.claude=claude
  self.completion=completion;self.includeTIFF=includeTIFF;quitDelivery=quitting;pendingQuit=false;encoding=true
  Task {
   do {
    let payload:Data
    if let png {payload=png} else {payload=try await Task.detached(priority:.userInitiated){try ScreenshotFile.pngData(from:image)}.value}
    guard sessionID==id else{return}
    data=payload;encoding=false
    if pendingQuit {askQuit()}
    else if options.saveToFile || quitting {chooseSave()}
    else {copyAndPaste()}
   } catch {
    guard sessionID==id else{return}
    encoding=false
    let alert=NSAlert();alert.messageText="截图编码失败";alert.informativeText=error.localizedDescription
    alert.runModal();finish(false)
   }
  }
 }
 private func chooseSave() {
  guard let id=sessionID,let data else{return}
  pasteTask?.cancel()
  let token=UUID();saveID=token
  let panel=NSSavePanel();savePanel=panel
  panel.allowedContentTypes=[.png];panel.canCreateDirectories=true
  panel.title="保存截图";panel.prompt=(quitDelivery || pendingQuit) ? "保存并退出":"保存"
  panel.directoryURL=FileManager.default.urls(for:.picturesDirectory,in:.userDomainMask).first
  let formatter=DateFormatter();formatter.dateFormat="yyyy-MM-dd HH.mm.ss.SSS"
  panel.nameFieldStringValue="ClawdSnip \(formatter.string(from:Date())).png"
  NSApp.activate(ignoringOtherApps:true)
  panel.begin { [weak self] response in
   guard let self,self.sessionID==id,self.saveID==token else{return}
   self.savePanel=nil;self.saveID=nil
   guard response == .OK,let url=panel.url else {
    if self.quitDelivery {self.finish(false)}
    else if self.pendingQuit {
     self.pendingQuit=false;NSApp.reply(toApplicationShouldTerminate:false)
     if self.options.saveToFile {self.chooseSave()}else{self.copyAndPaste()}
    } else {self.copyAndPaste()}
    return
   }
   self.writing=true
   Task {
    do {
     try await Task.detached(priority:.userInitiated){try ScreenshotFile.write(data,to:url)}.value
     guard self.sessionID==id else{return}
     self.writing=false;self.onMessage?("已保存截图")
     self.copyAndPaste()
    } catch {
     guard self.sessionID==id else{return}
     self.writing=false;self.saveFailed(error)
    }
   }
  }
 }
 private func saveFailed(_ error:Error) {
  let alert=NSAlert();alert.messageText="截图保存失败，图像仍保留"
  alert.informativeText=error.localizedDescription
  alert.addButton(withTitle:"重试保存")
  alert.addButton(withTitle:(quitDelivery || pendingQuit) ? "仅复制并退出":"仅复制并继续")
  alert.addButton(withTitle:(quitDelivery || pendingQuit) ? "取消退出":"取消输出")
  switch alert.runModal() {
  case .alertFirstButtonReturn:chooseSave()
  case .alertSecondButtonReturn:copyAndPaste()
  default:
   if pendingQuit && !quitDelivery {
    pendingQuit=false;NSApp.reply(toApplicationShouldTerminate:false);chooseSave()
   } else {finish(false)}
  }
 }
 private func copyAndPaste() {
  guard let id=sessionID,let data else{return}
  let clipboard=pasteboard
  clipboard.clearContents();clipboard.setData(data,forType:.png)
  // PNG is enough for long images; do not retain another full-size TIFF copy.
  if includeTIFF,let image,image.width*image.height<=4_000_000,let tiff=NSImage(data:data)?.tiffRepresentation {clipboard.setData(tiff,forType:.tiff)}
  if quitDelivery || pendingQuit {finish(true);return}
  guard let target=claude ?? NSRunningApplication.runningApplications(withBundleIdentifier:claudeBundleID).first,!target.isTerminated else {
   onMessage?("已复制到剪贴板");finish(true);return
  }
  target.unhide()
  if let url=target.bundleURL {
   let configuration=NSWorkspace.OpenConfiguration();configuration.activates=true;configuration.addsToRecentItems=false
   NSWorkspace.shared.openApplication(at:url,configuration:configuration)
  } else {target.activate(options:[])}
  guard options.autoPaste else{onMessage?("已复制 · ⌘V 粘贴");finish(true);return}
  guard AXIsProcessTrusted() else {
   _=AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt":true] as CFDictionary)
   onMessage?("已复制 · ⌘V 粘贴");finish(true);return
  }
  pasteTask=Task { [weak self] in
   for _ in 0..<15 {
    guard let self,self.sessionID==id,!Task.isCancelled else{return}
    if target.isActive {
     do {try await Task.sleep(nanoseconds:200_000_000)}catch{return}
     guard self.sessionID==id,!Task.isCancelled else{return}
     if target.isActive {postCommandV();self.onMessage?("已粘贴到 Claude")}
     else {self.onMessage?("已复制 · ⌘V 粘贴")}
     self.finish(true);return
    }
    do{try await Task.sleep(nanoseconds:100_000_000)}catch{return}
   }
   guard let self,self.sessionID==id,!Task.isCancelled else{return}
   self.onMessage?("已复制 · ⌘V 粘贴");self.finish(true)
  }
 }
 func shouldTerminate()->NSApplication.TerminateReply {
  guard isBusy else{return .terminateNow}
  if quitDelivery || pendingQuit{return .terminateLater}
  pendingQuit=true;pasteTask?.cancel()
  if writing || encoding{return .terminateLater}
  saveID=nil;savePanel?.cancel(nil);savePanel=nil
  DispatchQueue.main.async { [weak self] in self?.askQuit() }
  return .terminateLater
 }
 private func askQuit() {
  guard pendingQuit,isBusy else{return}
  let alert=NSAlert();alert.messageText="当前截图尚未完成输出"
  alert.informativeText="可以保存截图后退出，或丢弃本次结果。"
  alert.addButton(withTitle:"保存并退出");alert.addButton(withTitle:"丢弃并退出");alert.addButton(withTitle:"取消退出")
  switch alert.runModal() {
  case .alertFirstButtonReturn:chooseSave()
  case .alertSecondButtonReturn:finish(true)
  default:
   pendingQuit=false;NSApp.reply(toApplicationShouldTerminate:false)
   if options.saveToFile {chooseSave()}else{copyAndPaste()}
  }
 }
 private func finish(_ succeeded:Bool) {
  let callback=completion,reply=pendingQuit
  sessionID=nil;saveID=nil;completion=nil;savePanel?.cancel(nil);savePanel=nil
  pasteTask?.cancel();pasteTask=nil;image=nil;data=nil;claude?.unhide();claude=nil
  encoding=false;writing=false;pendingQuit=false;quitDelivery=false
  callback?(succeeded)
  if reply {DispatchQueue.main.async{NSApp.reply(toApplicationShouldTerminate:succeeded)}}
 }
}
