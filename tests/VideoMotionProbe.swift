import Cocoa
import AVFoundation

@main struct VideoMotionProbe {
 static func signature(_ image:CGImage)->[UInt8] {
  var bytes=[UInt8](repeating:0,count:32*18)
  bytes.withUnsafeMutableBytes { b in
   let c=CGContext(data:b.baseAddress,width:32,height:18,bitsPerComponent:8,bytesPerRow:32,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue)!
   c.draw(image,in:CGRect(x:0,y:0,width:32,height:18))
  }
  return bytes
 }
 static func main() async {
  do{try await run()}catch{fputs("FAIL: \(error.localizedDescription)\n",stderr);exit(1)}
 }
 static func run() async throws {
  let asset=AVURLAsset(url:URL(fileURLWithPath:CommandLine.arguments[1]))
  let duration=try await asset.load(.duration).seconds
  guard let video=try await asset.loadTracks(withMediaType:.video).first else{throw NSError(domain:"VideoMotionProbe",code:1,userInfo:[NSLocalizedDescriptionKey:"No video track"])}
  let size=try await video.load(.naturalSize),range=try await video.load(.timeRange)
  let reader=try AVAssetReader(asset:asset)
  let output=AVAssetReaderTrackOutput(track:video,outputSettings:nil)
  reader.add(output);guard reader.startReading() else{throw reader.error!}
  var count=0,first:Double?,last:Double?,nonMonotonic=0,presentationTimes=[Double]()
  while let sample=output.copyNextSampleBuffer(){
   let pts=CMSampleBufferGetPresentationTimeStamp(sample).seconds
   if let last,pts<=last{nonMonotonic+=1}
   if first==nil{first=pts};last=pts;count+=1;presentationTimes.append(pts)
  }
  guard reader.status == .completed else{throw reader.error!}
  let generator=AVAssetImageGenerator(asset:asset)
  generator.appliesPreferredTrackTransform=true;generator.maximumSize=CGSize(width:128,height:72)
  generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
  var signatures=[[UInt8]](),failedImages=0
  for i in 0..<12 {
   let time=range.start.seconds+max(0,range.duration.seconds-0.1)*Double(i)/11
   do{let result=try await generator.image(at:CMTime(seconds:time,preferredTimescale:600));signatures.append(signature(result.image))}
   catch{failedImages+=1}
  }
  var maximumDifference=0.0
  if let firstImage=signatures.first {
   for next in signatures.dropFirst(){
    var total=0.0
    for i in next.indices{total+=Double(abs(Int(firstImage[i])-Int(next[i])))}
    maximumDifference=max(maximumDifference,total/Double(next.count))
   }
  }
  let sortedTimes=presentationTimes.sorted()
  var maximumGap=0.0
  for i in 1..<max(1,sortedTimes.count){maximumGap=max(maximumGap,sortedTimes[i]-sortedTimes[i-1])}
  var finalThirdDifference=0.0
  if signatures.count>=10 {
   let late=Array(signatures.suffix(4))
   for next in late.dropFirst(){
    var total=0.0
    for i in next.indices{total+=Double(abs(Int(late[0][i])-Int(next[i])))}
    finalThirdDifference=max(finalThirdDifference,total/Double(next.count))
   }
  }
  var audioDurations=[Double]()
  for track in try await asset.loadTracks(withMediaType:.audio){audioDurations.append(try await track.load(.timeRange).duration.seconds)}
  // Compressed samples arrive in decode order; B-frame PTS reordering is expected.
  let result:[String:Any]=["duration":duration,"videoDuration":range.duration.seconds,"videoSamples":count,"videoFirstPTS":first ?? -1,"videoLastPTS":last ?? -1,"presentationOrderChanges":nonMonotonic,"maximumFrameGap":maximumGap,"width":size.width,"height":size.height,"audioDurations":audioDurations,"decodedImages":signatures.count,"failedImages":failedImages,"distinctImages":Set(signatures).count,"maximumMeanPixelChange":maximumDifference,"finalThirdMeanPixelChange":finalThirdDifference]
  print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys,.prettyPrinted]),encoding:.utf8)!)
  if CommandLine.arguments.contains("--require-motion") {
   let expected=CommandLine.arguments.first(where:{$0.hasPrefix("--expected-seconds=")}).flatMap{Double($0.dropFirst("--expected-seconds=".count))} ?? duration
   guard range.duration.seconds>=expected-0.5,range.duration.seconds>=duration-0.5,
         count>=Int(expected*5),maximumGap<=0.5,Set(signatures).count>=10,
         finalThirdDifference>=2 else{exit(1)}
  }
 }
}
