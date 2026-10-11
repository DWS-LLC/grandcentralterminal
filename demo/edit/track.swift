// Camera track for a generated plate: where a quad pinned on frame 0 sits
// in every later frame (Veo "locked" shots still drift and push in).
//
//   swift demo/edit/track.swift <clip> <quad x0,y0,...,x3,y3> <patch x,y,w,h>...
//
//   patch_i on frame 0 ──Vision translational registration──▶ shift d_i
//   fit  p' = s·p + b  over all patch centres (least squares: push + pan)
//   quad_n = s_n·quad_0 + b_n        -> JSON [[x0,y0,..,x3,y3], ...] on stdout
//
// Pixels, top-left origin. Patches go on static, textured set (window
// frames, beams, desk edges), far apart, never on the actor or a screen.

import AVFoundation
import CoreImage
import Vision

func numbers(_ s: String) -> [Double] {
    s.split(separator: ",").map { Double($0)! }
}

let args = CommandLine.arguments
guard args.count >= 5 else {
    FileHandle.standardError.write("usage: track.swift <clip> <quad> <patch x,y,w,h> <patch>...\n".data(using: .utf8)!)
    exit(2)
}
let quad = numbers(args[2])
let patches = args[3...].map(numbers)

let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let track = asset.tracks(withMediaType: .video)[0]
let size = track.naturalSize
let reader = try AVAssetReader(asset: asset)
let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
])
reader.add(output)
reader.startReading()

// CoreImage rect (bottom-left origin) for a top-left-origin patch.
func ciRect(_ p: [Double]) -> CGRect {
    CGRect(x: p[0], y: size.height - p[1] - p[3], width: p[2], height: p[3])
}

func crop(_ frame: CVPixelBuffer, _ r: CGRect) -> CIImage {
    CIImage(cvPixelBuffer: frame).cropped(to: r)
        .transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
}

// Content shift of one patch from reference to target, top-left pixels.
func shift(_ ref: CVPixelBuffer, _ frame: CVPixelBuffer, _ p: [Double]) throws -> (Double, Double)? {
    let r = ciRect(p)
    let request = VNTranslationalImageRegistrationRequest(targetedCIImage: crop(frame, r))
    try VNImageRequestHandler(ciImage: crop(ref, r)).perform([request])
    guard let obs = request.results?.first as? VNImageTranslationAlignmentObservation else {
        return nil
    }
    // alignmentTransform moves the target onto the reference: negate it,
    // and flip y back to a top-left origin.
    let t = obs.alignmentTransform
    return (-Double(t.tx), Double(t.ty))
}

// Least squares for x' = s·x + bx, y' = s·y + by over the patch centres.
func fit(_ src: [(Double, Double)], _ dst: [(Double, Double)]) -> (Double, Double, Double) {
    let n = Double(src.count)
    let mx = src.map(\.0).reduce(0, +) / n, my = src.map(\.1).reduce(0, +) / n
    let ux = dst.map(\.0).reduce(0, +) / n, uy = dst.map(\.1).reduce(0, +) / n
    var num = 0.0, den = 0.0
    for (a, b) in zip(src, dst) {
        num += (a.0 - mx) * (b.0 - ux) + (a.1 - my) * (b.1 - uy)
        den += (a.0 - mx) * (a.0 - mx) + (a.1 - my) * (a.1 - my)
    }
    let s = den > 0 ? num / den : 1
    return (s, ux - s * mx, uy - s * my)
}

let centres = patches.map { ($0[0] + $0[2] / 2, $0[1] + $0[3] / 2) }
var reference: CVPixelBuffer?
var quads: [[Double]] = []
while let sample = output.copyNextSampleBuffer() {
    guard let frame = CMSampleBufferGetImageBuffer(sample) else {
        continue
    }
    guard let ref = reference else {
        reference = frame
        quads.append(quad)
        continue
    }

    var src: [(Double, Double)] = [], dst: [(Double, Double)] = []
    for (p, c) in zip(patches, centres) {
        guard let (dx, dy) = try shift(ref, frame, p) else {
            continue
        }
        src.append(c)
        dst.append((c.0 + dx, c.1 + dy))
    }
    guard src.count >= 2 else {
        quads.append(quads.last!)
        continue
    }

    let (s, bx, by) = fit(src, dst)
    quads.append(stride(from: 0, to: 8, by: 2).flatMap { k in
        [s * quad[k] + bx, s * quad[k + 1] + by]
    })
}

let rounded = quads.map { $0.map { ($0 * 10).rounded() / 10 } }
print(String(data: try JSONSerialization.data(withJSONObject: rounded), encoding: .utf8)!)
