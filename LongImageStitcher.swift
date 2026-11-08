import Foundation
import CoreGraphics

struct GrayRows {
 let width:Int
 let height:Int
 let pixels:[UInt8]
 init(image:CGImage) throws {
  let width=min(64,image.width),height=image.height
  self.width=width;self.height=height
  guard width>0,height>0,height<=30000 else { throw RecordingProblem("截图尺寸无效或过大。") }
  var data=[UInt8](repeating:0,count:width*height)
  let succeeded=data.withUnsafeMutableBytes { buffer -> Bool in
   guard let context=CGContext(data:buffer.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else { return false }
   context.interpolationQuality = .low
   context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
   return true
  }
  guard succeeded else { throw RecordingProblem("无法分析截图内容。") }
  pixels=data
 }
 func difference(from other:Self)->Double {
  guard width==other.width,height==other.height else{return .infinity}
  var total=0.0
  for i in pixels.indices { total+=Double(abs(Int(pixels[i])-Int(other.pixels[i]))) }
  return total/Double(pixels.count)
 }
 var contrast:Double {
  let mean=pixels.reduce(0.0){$0+Double($1)}/Double(pixels.count)
  return pixels.reduce(0.0){$0+abs(Double($1)-mean)}/Double(pixels.count)
 }
 func error(against next:Self,shift:Int)->Double {
  let overlap=height-abs(shift)
  guard overlap>0 else{return .infinity}
  var sum=0.0,count=0
  for sample in 0..<32 {
   let row=sample*(overlap-1)/31
   let a=(row+max(0,shift))*width
   let b=(row+max(0,-shift))*width
   // Leave side borders and scrollbars out of the match.
   for col in stride(from:max(1,width/12),to:width-max(1,width/12),by:2) {
    sum+=Double(abs(Int(pixels[a+col])-Int(next.pixels[b+col])));count+=1
   }
  }
  return sum/Double(max(1,count))
 }
}

struct LongImageStitcher {
 enum Result:Equatable { case added(Int),duplicate,unmatched,reverse,limit }
 let maxPixels:Int
 let maxHeight:Int
 private var reference:GrayRows?
 private var chunks=[CGImage]()
 private(set) var width=0
 private(set) var height=0
 private var limited=false
 init(maxPixels:Int=40_000_000,maxHeight:Int=30_000) {self.maxPixels=maxPixels;self.maxHeight=maxHeight}
 mutating func accept(_ image:CGImage) throws -> Result {
  if limited{return .limit}
  if reference==nil {
   guard image.width>0,image.height>0,image.width<=maxPixels,
         image.height<=min(maxHeight,maxPixels/image.width) else {throw RecordingProblem("所选区域超出长截图尺寸上限，请缩小区域。")}
   let rows=try GrayRows(image:image)
   width=image.width;height=image.height;chunks=[image];reference=rows
   return .added(image.height)
  }
  let next=try GrayRows(image:image)
  guard let last=reference,last.width==next.width,last.height==next.height,image.width==width else{return .unmatched}
  if last.difference(from:next)<0.75{return .duplicate}
  guard min(last.contrast,next.contrast)>3 else{return .unmatched}
  let maximum=last.height-max(32,last.height/6)
  guard maximum>=4 else{return .unmatched}
  var candidates=[(shift:Int,error:Double)]()
  for amount in stride(from:4,through:maximum,by:1) {
   candidates.append((amount,last.error(against:next,shift:amount)))
   candidates.append((-amount,last.error(against:next,shift:-amount)))
  }
  guard var best=candidates.min(by:{$0.error<$1.error}) else{return .unmatched}
  for shift in (best.shift-2)...(best.shift+2) where abs(shift)>=4 && abs(shift)<=maximum {
   let error=last.error(against:next,shift:shift)
   if error<best.error{best=(shift,error)}
  }
  let allowed=max(2.0,min(last.contrast,next.contrast)*0.23)
  guard best.error<allowed else{return .unmatched}
  let separation=max(10,last.height/40)
  if let other=candidates.filter({abs($0.shift-best.shift)>separation}).min(by:{$0.error<$1.error}),
     other.error-best.error<max(0.75,best.error*0.25){return .unmatched}
  guard best.shift>0 else{return .reverse}
  let remaining=min(maxHeight,maxPixels/width)-height
  guard remaining>0 else{limited=true;return .limit}
  let added=min(best.shift,remaining)
  guard let tail=image.cropping(to:CGRect(x:0,y:image.height-best.shift,width:width,height:added)) else {throw RecordingProblem("无法拼接截图，请缩小区域后重试。")}
  // Cropped CGImages retain their parent's full backing. Copy only the appended strip.
  guard let copy=CGContext(data:nil,width:width,height:added,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw RecordingProblem("无法分配长截图条带。")}
  copy.interpolationQuality = .none
  copy.draw(tail,in:CGRect(x:0,y:0,width:width,height:added))
  guard let detached=copy.makeImage() else{throw RecordingProblem("无法复制长截图条带。")}
  chunks.append(detached);height+=added;reference=next
  if added<best.shift || height>=min(maxHeight,maxPixels/width){limited=true;return .limit}
  return .added(added)
 }
 func render() throws -> CGImage {
  guard width>0,height>0,!chunks.isEmpty,
        let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw RecordingProblem("还没有可用的长截图内容。")}
  context.interpolationQuality = .none
  var y=height
  for image in chunks {y-=image.height;context.draw(image,in:CGRect(x:0,y:y,width:width,height:image.height))}
  guard let image=context.makeImage() else{throw RecordingProblem("无法生成长截图。")}
  return image
 }
 mutating func renderAndRelease() throws -> CGImage {
  let image=try render();chunks.removeAll();reference=nil;return image
 }
}
