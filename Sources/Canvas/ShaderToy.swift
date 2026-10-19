// ShaderToy source -> Metal. A ShaderToy shader is just `mainImage`; we
// wrap it in the uniforms + entry point it expects, then translate with
// the glslang/SPIRV-Cross copies inside libghostty (see ShaderXlate).
//
//   user.glsl ─▶ prefix + #line 1 + user + suffix ─▶ GLSL 430 ─▶ MSL
//
// Bindings (decoration bindings survive into MSL as Metal indices):
//   iChannel0..3   texture/sampler 0..3
//   Globals        buffer 4

import Foundation
import ShaderXlate

enum ShaderToy {
    static let globalsIndex = 4
    static let channelCount = 4
    // spirv-cross renames GLSL's `main`.
    static let fragmentName = "main0"

    struct CompileError: Error, CustomStringConvertible {
        let description: String
    }

    // std140 uniform block. Order is ours (shaders bind by name), picked so
    // the Swift mirror needs no hidden padding. Keep ShaderToyGlobals in sync.
    private static let prefix = """
    #version 430 core

    layout(binding = \(globalsIndex), std140) uniform Globals {
        vec4  iMouse;
        vec4  iDate;
        vec3  iResolution;
        float iTime;
        float iTimeDelta;
        float iFrameRate;
        int   iFrame;
        float iSampleRate;
        float iChannelTime[4];
        vec3  iChannelResolution[4];
        float gctOpacity;
    };

    layout(binding = 0) uniform sampler2D iChannel0;
    layout(binding = 1) uniform sampler2D iChannel1;
    layout(binding = 2) uniform sampler2D iChannel2;
    layout(binding = 3) uniform sampler2D iChannel3;

    layout(location = 0) out vec4 gctFragColor;

    #define texture2D texture

    """

    // Metal's fragment origin is top-left, ShaderToy's bottom-left: flip.
    // Output is premultiplied for the compositor, the canvas background's
    // alpha scaling the shader's own.
    private static let suffix = """

    void main() {
        vec4 c = vec4(0.0);
        mainImage(c, vec2(gl_FragCoord.x, iResolution.y - gl_FragCoord.y));
        float a = clamp(c.a, 0.0, 1.0) * gctOpacity;
        gctFragColor = vec4(clamp(c.rgb, 0.0, 1.0) * a, a);
    }
    """

    // Wrap + translate. Errors carry glslang's log, with line numbers
    // matching the user's file (#line 1).
    static func msl(source user: String) throws -> String {
        let glsl = prefix + "#line 1\n" + user + suffix

        var err: UnsafeMutablePointer<CChar>?
        guard let out = glsl_to_msl(glsl, &err) else {
            let why = err.map { String(cString: $0) } ?? "unknown error"
            free(err)
            throw CompileError(description: why)
        }

        defer { free(out) }
        return String(cString: out)
    }
}

// Swift mirror of the Globals block, std140 offsets in comments. Tuples of
// Float pack like vec3; SIMD4 arrays model std140's 16-byte array stride.
struct ShaderToyGlobals {
    typealias Vec4x4 = (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

    var mouse = SIMD4<Float>.zero                      // 0
    var date = SIMD4<Float>.zero                       // 16
    var resolution: (Float, Float, Float) = (0, 0, 1)  // 32
    var time: Float = 0                                // 44
    var timeDelta: Float = 0                           // 48
    var frameRate: Float = 0                           // 52
    var frame: Int32 = 0                               // 56
    var sampleRate: Float = 44100                      // 60
    var channelTime: Vec4x4 = (.zero, .zero, .zero, .zero)        // 64
    var channelResolution: Vec4x4 = (.zero, .zero, .zero, .zero)  // 128
    var opacity: Float = 1                             // 192
}
