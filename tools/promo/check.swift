import AVFoundation
import AppKit
let a = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))   // prints duration/size/fps; writes a few frames as PNGs
let sem = DispatchSemaphore(value: 0)
Task {
    let d = try await a.load(.duration)
    let tr = try await a.loadTracks(withMediaType: .video)[0]
    let sz = try await tr.load(.naturalSize), fps = try await tr.load(.nominalFrameRate)
    print("duration \(d.seconds)s size \(sz) fps \(fps)")
    let g = AVAssetImageGenerator(asset: a); g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
    for t in [1.0, 5.0, 9.6, 11.6, 14.0] {
        let (img, _) = try await g.image(at: CMTime(seconds: t, preferredTimescale: 600))
        let rep = NSBitmapImageRep(cgImage: img)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "v\(t).png"))
    }
    sem.signal()
}
sem.wait()
