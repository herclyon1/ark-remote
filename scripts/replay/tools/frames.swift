// frames <video.mp4> <x,y,w,h> [<x,y,w,h> ...]
//
// Decodes a screen recording (Android `screenrecord` mp4) with AVFoundation and prints one JSON line per frame:
//   {"t": presentation time in ms, "r": [[dark pixel count, mean luma, checksum], ...]}  (one triple per rectangle)
// Dark = luma below 100 (text on a light sheet). The checksum is a position-weighted luma sum over every 2nd pixel, so
// any change inside the rectangle changes it. Used by the Android 400 ms gate measurement (run.py action "gate_measure").
import AVFoundation
import CoreVideo
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write("usage: frames <video> <x,y,w,h> ...\n".data(using: .utf8)!)
    exit(2)
}
let rects: [(Int, Int, Int, Int)] = args.dropFirst(2).map {
    let p = $0.split(separator: ",").map { Int($0) ?? 0 }
    return (p[0], p[1], p[2], p[3])
}
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let sem = DispatchSemaphore(value: 0)
var track: AVAssetTrack?
Task {
    track = try? await asset.loadTracks(withMediaType: .video).first
    sem.signal()
}
sem.wait()
guard let track else { print("{\"error\":\"no video track\"}"); exit(1) }
let reader = try AVAssetReader(asset: asset)
let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
out.alwaysCopiesSampleData = false
reader.add(out)
reader.startReading()
while let sb = out.copyNextSampleBuffer() {
    guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
    let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)) * 1000
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    var res: [String] = []
    for (rx, ry, rw, rh) in rects {
        var dark = 0, sum = 0, n = 0, ck: UInt64 = 0
        let x0 = max(0, rx), y0 = max(0, ry), x1 = min(w, rx + rw), y1 = min(h, ry + rh)
        if x1 > x0 && y1 > y0 {
            for y in stride(from: y0, to: y1, by: 1) {
                let p = base + y * row
                for x in stride(from: x0, to: x1, by: 1) {
                    let b = Int(p[x * 4]), g = Int(p[x * 4 + 1]), r = Int(p[x * 4 + 2])
                    let l = (r * 299 + g * 587 + b * 114) / 1000
                    if l < 100 { dark += 1 }
                    sum += l; n += 1
                    if (x + y) & 1 == 0 { ck = ck &+ UInt64(l) &* UInt64(x &* 31 &+ y &* 17 &+ 1) }
                }
            }
        }
        res.append("[\(dark),\(n > 0 ? sum / n : 0),\(ck % 1_000_000_007)]")
    }
    CVPixelBufferUnlockBaseAddress(pb, .readOnly)
    print("{\"t\":\(Int(t.rounded())),\"w\":\(w),\"h\":\(h),\"r\":[\(res.joined(separator: ","))]}")
}
if reader.status == .failed {
    print("{\"error\":\"\(reader.error.map { "\($0)" } ?? "?")\"}")
    exit(1)
}
