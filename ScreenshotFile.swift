import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum ScreenshotFile {
 static func decode(_ data:Data) throws -> CGImage {
  guard let source=CGImageSourceCreateWithData(data as CFData,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else {
   throw RecordingProblem("无法读取截图图像。")
  }
  return image
 }
 static func pngData(from image:CGImage) throws -> Data {
  let data=NSMutableData()
  guard let destination=CGImageDestinationCreateWithData(data,UTType.png.identifier as CFString,1,nil) else { throw RecordingProblem("无法创建 PNG 图像。") }
  CGImageDestinationAddImage(destination,image,nil)
  guard CGImageDestinationFinalize(destination) else { throw RecordingProblem("PNG 编码失败，请重试。") }
  return data as Data
 }
 static func write(_ data:Data,to url:URL) throws { try data.write(to:url,options:.atomic) }
}
