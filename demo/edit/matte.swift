// Person matte for a generated plate, so real GCT footage can go on the
// wall *behind* the actor:
//
//   swift demo/edit/matte.swift <clip.mp4> <out-dir>
//
//   clip --AVAssetReader--> frame --Vision person segmentation--> m00000.png
//
// White = person (keep the plate), black = background (composite goes
// there). Vision's .accurate level runs on the Neural Engine.

import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: matte.swift <clip> <out-dir>\n".data(using: .utf8)!)
    exit(2)
}
let clip = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let asset = AVURLAsset(url: clip)
let track = asset.tracks(withMediaType: .video)[0]
let reader = try AVAssetReader(asset: asset)
let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
])
reader.add(output)
reader.startReading()

// Mask comes back at Vision's working size; scale it to the clip's frame.
let size = track.naturalSize
let ctx = CIContext()
let request = VNGeneratePersonSegmentationRequest()
request.qualityLevel = .accurate
request.outputPixelFormat = kCVPixelFormatType_OneComponent8

var index = 0
while let sample = output.copyNextSampleBuffer() {
    guard let frame = CMSampleBufferGetImageBuffer(sample) else {
        continue
    }
    try VNImageRequestHandler(cvPixelBuffer: frame).perform([request])
    guard let mask = request.results?.first?.pixelBuffer else {
        continue
    }

    let small = CIImage(cvPixelBuffer: mask)
    let scaled = small.transformed(by: CGAffineTransform(
        scaleX: size.width / small.extent.width, y: size.height / small.extent.height))
    let cg = ctx.createCGImage(scaled, from: CGRect(origin: .zero, size: size),
                               format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())!

    let url = outDir.appendingPathComponent(String(format: "m%05d.png", index))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil)
    CGImageDestinationFinalize(dest)
    index += 1
}
print("\(index) mattes -> \(outDir.path)")
