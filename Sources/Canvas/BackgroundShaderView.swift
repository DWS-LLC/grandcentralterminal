// Canvas background drawn by a ShaderToy shader ([background] shader).
// Screen space, under the world view: panes slide over it, it doesn't pan.
// One fullscreen triangle per frame; the layer is non-opaque, so shader
// alpha (times the canvas background's) lets the desktop through.
//
//   CanvasView.applyTheme ─▶ load(path:) ─▶ ShaderToy.msl ─▶ pipeline
//   MTKView draw loop (fps) ─▶ draw(in:) ─▶ Globals + triangle

import AppKit
import MetalKit

final class BackgroundShaderView: MTKView, MTKViewDelegate {
    private let queue: MTLCommandQueue
    private let vertexFunction: MTLFunction
    private let channel: MTLTexture
    private let sampler: MTLSamplerState
    private var pipeline: MTLRenderPipelineState?
    // Source of the live pipeline: reloads skip the compile when unchanged.
    private var loadedSource: String?

    private var globals = ShaderToyGlobals()
    private let startTime = CACurrentMediaTime()
    private var lastFrameTime: CFTimeInterval?

    // A shader compiled at some point; draws even if a later load failed.
    var isReady: Bool { pipeline != nil }

    // Canvas background alpha, multiplied into the shader's.
    var opacity: Float {
        get { globals.opacity }
        set { globals.opacity = newValue }
    }

    // Fullscreen triangle from vertex_id: (-1,-1) (3,-1) (-1,3).
    private static let vertexSource = """
    #include <metal_stdlib>
    using namespace metal;
    vertex float4 gct_fullscreen(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        return float4(p * 2.0 - 1.0, 0.0, 1.0);
    }
    """

    init?(rect frame: NSRect) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let lib = try? device.makeLibrary(source: Self.vertexSource, options: nil),
              let vertex = lib.makeFunction(name: "gct_fullscreen"),
              let channel = Self.blankTexture(device),
              let sampler = device.makeSamplerState(descriptor: MTLSamplerDescriptor())
        else { return nil }

        self.queue = queue
        self.vertexFunction = vertex
        self.channel = channel
        self.sampler = sampler
        super.init(frame: frame, device: device)

        // Transparent layer: the compositor blends our premultiplied output
        // over the desktop.
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        layer?.isOpaque = false
        framebufferOnly = true
        enableSetNeedsDisplay = false
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // Never takes events: CanvasView routes everything itself.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // Compile `path` into the pipeline. Throws the compiler log; on failure
    // the previous pipeline (if any) stays up.
    func load(path: String) throws {
        let source = try String(contentsOfFile: path, encoding: .utf8)
        if source == loadedSource { return }

        let msl = try ShaderToy.msl(source: source)
        guard let device else { return }
        let lib = try device.makeLibrary(source: msl, options: nil)
        guard let fragment = lib.makeFunction(name: ShaderToy.fragmentName) else {
            throw ShaderToy.CompileError(description: "no \(ShaderToy.fragmentName) in MSL")
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertexFunction
        desc.fragmentFunction = fragment
        desc.colorAttachments[0].pixelFormat = colorPixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: desc)
        loadedSource = source
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline,
              let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: pass)
        else { return }

        tick()

        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&globals, length: MemoryLayout<ShaderToyGlobals>.stride,
                             index: ShaderToy.globalsIndex)
        for i in 0..<ShaderToy.channelCount {
            enc.setFragmentTexture(channel, index: i)
            enc.setFragmentSamplerState(sampler, index: i)
        }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()

        cmd.present(drawable)
        cmd.commit()
    }

    // MARK: Uniforms

    // Advance the ShaderToy clock, resolution, mouse, and date.
    private func tick() {
        let now = CACurrentMediaTime()
        let dt = lastFrameTime.map { now - $0 } ?? 0
        lastFrameTime = now

        globals.time = Float(now - startTime)
        globals.timeDelta = Float(dt)
        globals.frameRate = dt > 0 ? Float(1 / dt) : Float(preferredFramesPerSecond)
        globals.frame &+= 1

        let size = drawableSize
        globals.resolution = (Float(size.width), Float(size.height), 1)

        // Hover position in drawable pixels, bottom-left origin (ShaderToy
        // only reports it while dragging; hover is more fun on a canvas).
        if let window {
            let p = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            let scale = bounds.width > 0 ? size.width / bounds.width : 1
            globals.mouse.x = Float(p.x * scale)
            globals.mouse.y = Float(p.y * scale)
        }

        // (year, month 0-11, day, seconds since midnight), as in WebGL.
        let date = Date()
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let midnight = Calendar.current.startOfDay(for: date)
        globals.date = SIMD4(Float(c.year ?? 0), Float((c.month ?? 1) - 1),
                             Float(c.day ?? 0), Float(date.timeIntervalSince(midnight)))
    }

    // 1x1 transparent stand-in for iChannel0..3: shaders that sample a
    // channel compile and read black instead of failing.
    private static func blankTexture(_ device: MTLDevice) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }

        var pixel: UInt32 = 0
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                    withBytes: &pixel, bytesPerRow: MemoryLayout<UInt32>.size)
        return tex
    }
}
