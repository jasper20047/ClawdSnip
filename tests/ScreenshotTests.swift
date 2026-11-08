import Cocoa
import ImageIO

private var trackedFrameReleases=0
private func trackedFrame(_ image:CGImage)->CGImage {
 let w=image.width,h=image.height
 let buffer=UnsafeMutableRawPointer.allocate(byteCount:w*h*4,alignment:16)
 let context=CGContext(data:buffer,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
 context.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
 let provider=CGDataProvider(dataInfo:nil,data:buffer,size:w*h*4,releaseData:{_,bytes,_ in
  trackedFrameReleases+=1;UnsafeMutableRawPointer(mutating:bytes).deallocate()
 })!
 return CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
}

@main struct ScreenshotTests {
 static func main() throws {
  var count=0
  func check(_ value:Bool,_ message:String) { count+=1; if !value{fputs("FAIL: \(message)\n",stderr);exit(1)} }
  let domain="ClawdSnip-screenshot-tests-\(UUID().uuidString)"
  let defaults=UserDefaults(suiteName:domain)!
  defer { defaults.removePersistentDomain(forName:domain) }
  check(!ScreenshotOutputOptions.saved(in:defaults).saveToFile,"saving is opt-in")
  check(ScreenshotOutputOptions.saved(in:defaults).autoPaste,"old paste default preserved")
  for save in [false,true] { for paste in [false,true] {
   let value=ScreenshotOutputOptions(saveToFile:save,autoPaste:paste)
   value.save(in:defaults)
   check(ScreenshotOutputOptions.saved(in:defaults)==value,"save/paste independent and persisted")
  }}
  func fixture(seed:UInt32=21,height:Int=1600) -> CGImage {
   let w=256
   var bytes=[UInt8](repeating:255,count:w*height*4)
   for y in 0..<height { for x in 0..<w {
    let hash=(UInt32(y)&*1664525)&+UInt32(x)&*1013904223&+seed
    let v=UInt8((hash ^ (hash>>11) ^ (hash>>19)) & 255)
    let i=(y*w+x)*4;bytes[i]=v;bytes[i+1]=v;bytes[i+2]=v
   }}
   let provider=CGDataProvider(data:Data(bytes) as CFData)!
   return CGImage(width:w,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.noneSkipLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
  }
  let whole=fixture()
  func frame(_ y:Int)->CGImage { whole.cropping(to:CGRect(x:0,y:y,width:256,height:400))! }
  var stitcher=LongImageStitcher(maxPixels:40_000_000,maxHeight:30_000)
  check(try stitcher.accept(frame(0)) == .added(400),"first frame accepted")
  check(try stitcher.accept(frame(0)) == .duplicate,"duplicate frame ignored")
  check(try stitcher.accept(frame(180)) == .added(180),"true overlap detected")
  check(try stitcher.accept(frame(360)) == .added(180),"continuous overlap detected")
  check(stitcher.height==760,"no duplicated overlap rows")
  check(try stitcher.accept(frame(180)) == .reverse,"reverse scroll not appended")
  check(stitcher.height==760,"reverse leaves result intact")
  var odd=LongImageStitcher()
  _=try odd.accept(frame(0))
  check(try odd.accept(frame(181)) == .added(181),"odd physical-pixel scroll matches")
  let unrelated=fixture(seed:998).cropping(to:CGRect(x:0,y:0,width:256,height:400))!
  check(try stitcher.accept(unrelated) == .unmatched,"non-overlap rejected")
  var memory=LongImageStitcher()
  _=try memory.accept(frame(0))
  var transient:CGImage?=autoreleasepool{trackedFrame(frame(180))}
  _=try autoreleasepool{try memory.accept(transient!)}
  transient=nil
  check(trackedFrameReleases==1,"tail does not retain full source-frame backing")
  let combined=try stitcher.render()
  check(combined.width==256 && combined.height==760,"composed dimensions")
  let expected=whole.cropping(to:CGRect(x:0,y:0,width:256,height:760))!
  let left=try GrayRows(image:combined),right=try GrayRows(image:expected)
  check(left.difference(from:right)<0.01,"composed image has exact expected row ordering")
  var bounded=LongImageStitcher(maxPixels:256*500,maxHeight:30000)
  _=try bounded.accept(frame(0))
  check(try bounded.accept(frame(180)) == .limit,"partial tail clipped at pixel limit")
  check(bounded.height==500,"pixel limit honored")
  let limitedRows=try GrayRows(image:bounded.render())
  let limitedExpected=try GrayRows(image:whole.cropping(to:CGRect(x:0,y:0,width:256,height:500))!)
  check(limitedRows.difference(from:limitedExpected)<0.01,"clipped tail keeps contiguous rows at limit")
  do { var tiny=LongImageStitcher(maxPixels:100,maxHeight:10); _=try tiny.accept(frame(0));check(false,"oversized first frame rejected") } catch { count+=1 }
  let directory=FileManager.default.temporaryDirectory.appendingPathComponent("ClawdSnip-image-test-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
  defer { try? FileManager.default.removeItem(at:directory) }
  let png=try ScreenshotFile.pngData(from:combined)
  let url=directory.appendingPathComponent("result.png")
  try ScreenshotFile.write(png,to:url)
  let decoded=try ScreenshotFile.decode(Data(contentsOf:url))
  check(decoded.width==256 && decoded.height==760,"saved PNG decodes")
  do { try ScreenshotFile.write(png,to:directory.appendingPathComponent("missing/no.png"));check(false,"invalid destination reports failure") } catch { count+=1 }
  print("PASS: \(count) screenshot output, PNG, overlap, composition and limit checks")
 }
}
