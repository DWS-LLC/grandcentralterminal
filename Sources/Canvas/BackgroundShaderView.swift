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
    private var mouseWasDown = false
    private static let leftButtonMask = 1

    // A shader compiled at some point; draws even if a later load failed.
    var isReady: Bool { pipeline != nil }

    // Drawable pixels per backing pixel. Below 1 renders smaller and the
    // compositor stretches it: heavy raymarchers want 0.5.
    var renderScale: CGFloat = 1 {
        didSet { fitDrawable() }
    }

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
              let channel = Self.noiseTexture(device, queue),
              let sampler = device.makeSamplerState(descriptor: Self.channelSampler())
        else { return nil }

        self.queue = queue
        self.vertexFunction = vertex
        self.channel = channel
        self.sampler = sampler
        let side = Float(Self.noiseSize)
        let res = SIMD4<Float>(side, side, 1, 0)
        globals.channelResolution = (res, res, res, res)
        super.init(frame: frame, device: device)

        // Transparent layer: the compositor blends our premultiplied output
        // over the desktop.
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        layer?.isOpaque = false
        framebufferOnly = true
        enableSetNeedsDisplay = false
        autoResizeDrawable = false
        delegate = self
        fitDrawable()
    }

    required init(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitDrawable()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        fitDrawable()
    }

    // Drawable = bounds x backing scale x renderScale.
    private func fitDrawable() {
        let backing = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let scale = backing * renderScale
        drawableSize = CGSize(width: max(1, (bounds.width * scale).rounded()),
                              height: max(1, (bounds.height * scale).rounded()))
    }

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
        NSLog("[gct] background shader compiled: \(path)")
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

        tickMouse()

        // (year, month 0-11, day, seconds since midnight), as in WebGL.
        let date = Date()
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let midnight = Calendar.current.startOfDay(for: date)
        globals.date = SIMD4(Float(c.year ?? 0), Float((c.month ?? 1) - 1),
                             Float(c.day ?? 0), Float(date.timeIntervalSince(midnight)))
    }

    // ShaderToy iMouse in drawable pixels, bottom-left origin:
    //   xy  position while the left button is down (held after release)
    //   zw  press position; w < 0 after the press frame, z < 0 once released
    private func tickMouse() {
        let down = NSApp.isActive && NSEvent.pressedMouseButtons & Self.leftButtonMask != 0
        let pressed = down && !mouseWasDown
        let released = !down && mouseWasDown
        mouseWasDown = down

        if released {
            globals.mouse.z = -abs(globals.mouse.z)
            return
        }
        guard down, let window else { return }

        let p = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let scale = bounds.width > 0 ? drawableSize.width / bounds.width : 1
        globals.mouse.x = Float(p.x * scale)
        globals.mouse.y = Float(p.y * scale)

        if pressed {
            globals.mouse.z = globals.mouse.x
            globals.mouse.w = globals.mouse.y
        } else {
            globals.mouse.w = -abs(globals.mouse.w)
        }
    }

    // MARK: Channels

    // Stand-in for ShaderToy's "RGBA Noise Medium" on iChannel0..3, so noise
    // shaders work unconfigured. Fixed seed: same background every launch.
    // R(x, y) = G(x + 37, y + 239), iq's trick: one bilinear lookup returns
    // two adjacent z slices of 3D noise (uv = xy + (37, 239) * z).
    private static let noiseSize = 256
    private static let noiseSliceStep = (x: 37, y: 239)
    private static let noiseSeed: UInt64 = 0x6763_745F_6E6F_6973

    private static func noiseTexture(_ device: MTLDevice, _ queue: MTLCommandQueue) -> MTLTexture? {
        let n = noiseSize
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: n, height: n, mipmapped: true)
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }

        // G, B, A random; R is G shifted one z slice.
        var rng = SplitMix64(seed: noiseSeed)
        var rgba = [UInt8](repeating: 0, count: n * n * 4)
        for i in 0..<(n * n) {
            rgba[i * 4 + 1] = rng.byte()
            rgba[i * 4 + 2] = rng.byte()
            rgba[i * 4 + 3] = rng.byte()
        }
        for y in 0..<n {
            for x in 0..<n {
                let gx = (x + noiseSliceStep.x) % n
                let gy = (y + noiseSliceStep.y) % n
                rgba[(y * n + x) * 4] = rgba[(gy * n + gx) * 4 + 1]
            }
        }
        tex.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0,
                    withBytes: rgba, bytesPerRow: n * 4)

        // Mips for plain texture() calls; textureLod(.., 0) reads level 0.
        guard let cmd = queue.makeCommandBuffer(),
              let blit = cmd.makeBlitCommandEncoder() else { return tex }
        blit.generateMipmaps(for: tex)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return tex
    }

    // ShaderToy's texture defaults: repeat wrap, trilinear.
    private static func channelSampler() -> MTLSamplerDescriptor {
        let desc = MTLSamplerDescriptor()
        desc.sAddressMode = .repeat
        desc.tAddressMode = .repeat
        desc.minFilter = .linear
        desc.magFilter = .linear
        desc.mipFilter = .linear
        return desc
    }
}

// Tiny seedable PRNG for the channel noise.
private struct SplitMix64 {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func byte() -> UInt8 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return UInt8(truncatingIfNeeded: z ^ (z >> 31))
    }
}
