import AppKit
import Metal
import QuartzCore
import simd

// Screen-edge light drawn with Metal: one soft, continuous glow hugging the
// physical screen border (rounded corners, and around the camera housing on
// notched MacBooks, like light spilling out from behind it), the way a car's
// ambient strip lights a dashboard edge.
//
// How it draws: four quads cover only the border band (the middle of the
// screen is never shaded); the fragment shader takes the signed distance to
// "rounded screen rectangle minus notch", turns it into a sharp core line plus
// two exponential falloffs, and colors it by the position along the
// perimeter, so the palette flows around the screen as one strip.
//
// Cost: the drawable is 0.75 px per point (the glow is soft; the window
// server scales it up), one command buffer per frame per screen, uniforms by
// `setVertexBytes` / `setFragmentBytes`, a reused pass descriptor, and no draw
// at all when nothing changed or the light is off (one clearing frame, then
// nothing). The shader is compiled once at runtime from source (no offline
// Metal compiler with the Command Line Tools).
//
// Technique notes: the idea of a full-screen transparent Metal overlay with a
// runtime-compiled border shader comes from MacGlow
// (github.com/ogunkirikci/macglow, MIT). This file is SparkV's own
// implementation (SDF border, notch union, perimeter color flow); no MacGlow
// code is copied.

/// Matches `EdgeUniforms` in the shader (ten float4s, 160 bytes).
struct AmbientEdgeUniforms: Equatable {
    /// Width, height (points), corner radius (points), drawable pixels per point.
    var screen = SIMD4<Float>(0, 0, 0, 1)
    /// Notch left x, right x, height (0 = no notch), bottom corner radius (points, y down from the top).
    var notch = SIMD4<Float>(0, 0, 0, 0)
    /// Glow width (points), brightness 0...1, sparkle 0...1, reach (points of border band drawn).
    var glow = SIMD4<Float>(0, 0, 0, 0)
    /// Base palette position, wobble amplitude, flow phase (laps), winding 0...1 (Wave).
    var flow = SIMD4<Float>(0, 0, 0, 0)
    /// Palette color count, core line width (points), unused, unused.
    var misc = SIMD4<Float>(1, 1.4, 0, 0)
    var c0 = SIMD4<Float>(1, 0.16, 0.2, 1)
    var c1 = SIMD4<Float>(1, 0.16, 0.2, 1)
    var c2 = SIMD4<Float>(1, 0.16, 0.2, 1)
    var c3 = SIMD4<Float>(1, 0.16, 0.2, 1)
}

/// The shared device, queue and pipeline (built once; nil if Metal or the
/// shader is unavailable, then the panels use the Core Animation strips).
/// Immutable and made of thread-safe Metal objects, so it can be built off
/// the main thread: compiling the shader from source takes ~200 ms the first
/// time, which `prewarm()` keeps away from the first show of the edges.
final class AmbientEdgeGPU: @unchecked Sendable {
    /// Lazily built, once, on whichever thread asks first (`prewarm()`'s
    /// background queue when the edges are enabled).
    static let shared: AmbientEdgeGPU? = AmbientEdgeGPU()

    @MainActor private static var prewarmRequested = false

    /// Builds `shared` on a background queue (once). Call when the screen
    /// edges may be shown soon; harmless if `shared` is already built.
    @MainActor static func prewarm() {
        guard !prewarmRequested else { return }
        prewarmRequested = true
        DispatchQueue.global(qos: .utility).async { _ = AmbientEdgeGPU.shared }
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            NSLog("SparkV Ambient Light: no Metal device, screen edges use Core Animation")
            return nil
        }
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let vertex = library.makeFunction(name: "ambientEdgeVertex"),
                  let fragment = library.makeFunction(name: "ambientEdgeFragment") else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "SparkV ambient edge"
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            // The bands don't overlap and the pass clears: plain writes, no blending.
            descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = false
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("SparkV Ambient Light: edge shader failed (\(error)), screen edges use Core Animation")
            return nil
        }
        self.device = device
        self.queue = queue
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct EdgeUniforms {
        float4 screen;  // W, H (pt), corner radius (pt), px per pt
        float4 notch;   // x0, x1, height (0 = none), bottom radius (pt)
        float4 glow;    // width (pt), brightness, sparkle, reach (pt)
        float4 flow;    // base, wobble amplitude, flow phase, winding
        float4 misc;    // color count, core width (pt)
        float4 c[4];
    };

    struct EdgeVOut {
        float4 position [[position]];
        float2 p;       // points, origin top-left, y down
    };

    // Four quads (top, bottom, left, right) covering only the lit border band.
    vertex EdgeVOut ambientEdgeVertex(uint vid [[vertex_id]], constant EdgeUniforms &u [[buffer(0)]]) {
        float W = u.screen.x, H = u.screen.y;
        float reach = min(u.glow.w, 0.5 * min(W, H));
        float topReach = min(max(reach, u.notch.z + reach), H - reach);
        uint band = vid / 6;
        uint k = vid % 6;
        float4 r;
        if (band == 0)      r = float4(0, 0, W, topReach);
        else if (band == 1) r = float4(0, H - reach, W, H);
        else if (band == 2) r = float4(0, topReach, reach, H - reach);
        else                r = float4(W - reach, topReach, W, H - reach);
        float2 t = float2((k == 1 || k == 4 || k == 5) ? 1.0 : 0.0, (k == 2 || k == 3 || k == 5) ? 1.0 : 0.0);
        float2 p = mix(r.xy, r.zw, t);
        EdgeVOut o;
        o.position = float4(p.x / W * 2.0 - 1.0, 1.0 - p.y / H * 2.0, 0.0, 1.0);
        o.p = p;
        return o;
    }

    // Signed distance to a rounded box (negative inside).
    static float sdRoundBox(float2 p, float2 c, float2 h, float r) {
        float2 q = abs(p - c) - h + r;
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    // Smooth minimum: rounds the inner corners where the notch meets the top edge.
    static float smin(float a, float b, float k) {
        float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
        return mix(b, a, h) - k * h * (1.0 - h);
    }

    // Cyclic palette with smoothstep blends (same feel as the CGColor ramp).
    static float3 paletteAt(float pos, constant EdgeUniforms &u) {
        int n = clamp(int(u.misc.x + 0.5), 1, 4);
        float t = fract(pos) * float(n);
        int i = min(int(t), n - 1);
        float f = t - float(i);
        f = f * f * (3.0 - 2.0 * f);
        return mix(u.c[i].rgb, u.c[(i + 1) % n].rgb, f);
    }

    fragment float4 ambientEdgeFragment(EdgeVOut vin [[stage_in]], constant EdgeUniforms &u [[buffer(0)]]) {
        float2 p = vin.p;
        float W = u.screen.x, H = u.screen.y;
        float2 halfSize = float2(W, H) * 0.5;

        // Region = rounded screen minus the notch. `outside` > 0 outside it,
        // `dist` = distance inward from its border.
        float dScreen = sdRoundBox(p, halfSize, halfSize, u.screen.z);
        float outside = dScreen;
        float dist = -dScreen;
        if (u.notch.z > 0.5) {
            float ext = 40.0;   // the housing continues above the top edge
            float2 nc = float2((u.notch.x + u.notch.y) * 0.5, (u.notch.z - ext) * 0.5);
            float2 nh = float2((u.notch.y - u.notch.x) * 0.5, (u.notch.z + ext) * 0.5);
            float dNotch = sdRoundBox(p, nc, nh, u.notch.w);
            outside = max(outside, -dNotch);
            dist = smin(dist, dNotch, 7.0);
        }
        float d = max(dist, 0.0);

        // Thin bright core at the edge, a soft halo, and a wide faint bloom.
        float w = max(u.glow.x, 1.0);
        float core = exp(-d / max(u.misc.y, 0.5));
        float halo = exp(-d / (0.5 * w));
        float bloom = exp(-d / (1.2 * w));
        float sparkle = u.glow.z;
        float energy = (0.5 + 0.3 * sparkle) * core + 0.78 * halo + 0.34 * bloom;

        // Position along the perimeter, clockwise from the top-left corner, 0...1.
        float dl = p.x, dr = W - p.x, dt = p.y, db = H - p.y;
        float m = min(min(dl, dr), min(dt, db));
        float s;
        if (m == dt)      s = p.x;
        else if (m == dr) s = W + p.y;
        else if (m == db) s = 2.0 * W + H - p.x;
        else              s = 2.0 * W + 2.0 * H - p.y;
        s /= 2.0 * (W + H);

        // Wave winds the whole palette once around the screen (it travels by
        // the base position); the other modes wobble around the base color,
        // the wobble itself drifting around the screen, so the strip has no seam.
        float ph = u.flow.z;
        float wobble = u.flow.y * (0.7 * sin(6.2831853 * (s - ph)) + 0.3 * sin(12.5663706 * (s + 0.6 * ph)));
        float3 color = paletteAt(u.flow.x + mix(wobble, s, u.flow.w), u);
        color = mix(color, float3(1.0), (0.18 + 0.32 * sparkle) * core);

        // 1 px antialiasing at the region border (the notch's sides).
        float aa = clamp(0.5 - outside * u.screen.w, 0.0, 1.0);
        // Dither against banding in the long, soft falloff.
        float noise = fract(sin(dot(vin.position.xy, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
        float a = clamp(energy * u.glow.y * aa + noise / 255.0, 0.0, 1.0);
        return float4(color * a, a);   // premultiplied
    }
    """
}

/// One screen's Metal glow: a `CAMetalLayer` filling the edge panel.
@MainActor
final class AmbientEdgeMetalRenderer {
    let layer = CAMetalLayer()
    private let gpu: AmbientEdgeGPU
    private let pass = MTLRenderPassDescriptor()
    private var uniforms = AmbientEdgeUniforms()
    private var lastDrawn: AmbientEdgeUniforms?
    private var clearedDark = false
    /// The last two command buffers: a frame is skipped while the older one
    /// is still on the GPU, so the main thread never waits for a drawable.
    private var inFlight: [MTLCommandBuffer?] = [nil, nil]
    private var slot = 0
    private var edgeWidth: Float = 16
    private var flowPhase = 0.0
    private var lastTime: Double?

    /// Drawable pixels per point: the light is soft, so less than the
    /// backing scale is invisible and saves fill and bandwidth.
    static let pixelsPerPoint: CGFloat = 0.75

    init(gpu: AmbientEdgeGPU) {
        self.gpu = gpu
        layer.device = gpu.device
        layer.pixelFormat = AmbientEdgeGPU.pixelFormat
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.presentsWithTransaction = false
        layer.maximumDrawableCount = 3
        layer.allowsNextDrawableTimeout = true
        layer.needsDisplayOnBoundsChange = false
        layer.magnificationFilter = .linear
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "frame": NSNull(), "contents": NSNull(),
                         "opacity": NSNull(), "hidden": NSNull()]
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
    }

    /// `size`: the screen in points. `notch`: the camera housing's left and
    /// right x and height (points from the top-left), nil without one.
    func layout(size: CGSize, backingScale: CGFloat, cornerRadius: CGFloat,
                notch: (x0: CGFloat, x1: CGFloat, height: CGFloat)?, edgeWidth: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.frame = CGRect(origin: .zero, size: size)
        layer.contentsScale = backingScale
        let scale = min(backingScale, Self.pixelsPerPoint)
        layer.drawableSize = CGSize(width: max(1, (size.width * scale).rounded()),
                                    height: max(1, (size.height * scale).rounded()))
        CATransaction.commit()
        uniforms.screen = SIMD4(Float(size.width), Float(size.height), Float(cornerRadius), Float(scale))
        setNotchTarget(notch, radius: 9)
        uniforms.notch = notchTarget
        self.edgeWidth = Float(edgeWidth)
        invalidate()
    }

    /// Where the cut-out around the island should be; the drawn one glides there.
    private var notchTarget = SIMD4<Float>(repeating: 0)

    func setNotchTarget(_ notch: (x0: CGFloat, x1: CGFloat, height: CGFloat)?, radius: CGFloat) {
        if let notch, notch.x1 > notch.x0, notch.height > 0 {
            notchTarget = SIMD4(Float(notch.x0), Float(notch.x1), Float(notch.height), Float(max(4, min(radius, 24))))
        } else {
            notchTarget = .zero
        }
    }

    func invalidate() {
        lastDrawn = nil
        clearedDark = false
    }

    func render(_ frame: AmbientVisualFrame, palette: AmbientLightPalette, mode: AmbientLightMode,
                intensity: Double, reduceMotion: Bool) {
        let now = CACurrentMediaTime()
        let dt = min(0.1, max(0, now - (lastTime ?? now)))
        lastTime = now

        let brightness = (frame.brightness * 512).rounded() / 512
        guard brightness > 0.5 / 255 else {
            // Off: one transparent frame, then nothing until it lights again.
            if !clearedDark { draw(clearOnly: true) }
            return
        }
        clearedDark = false

        // Slow drift of the colors around the screen (Wave travels by its own phase).
        if !reduceMotion {
            let lapsPerSecond: Double
            switch mode {
            case .ambient: lapsPerSecond = 1.0 / 60
            case .pulse: lapsPerSecond = 1.0 / 40
            case .disco: lapsPerSecond = 1.0 / 16
            case .wave, .off: lapsPerSecond = 1.0 / 90
            }
            flowPhase += dt * lapsPerSecond * (0.6 + 0.8 * frame.bloom)
            flowPhase -= floor(flowPhase)
        }

        // Glide the cut-out with the island's spring (no jump when it resizes).
        if uniforms.notch != notchTarget {
            if uniforms.notch.z < 0.5 || notchTarget.z < 0.5 || reduceMotion {
                uniforms.notch = notchTarget
            } else {
                let k = Float(1 - exp(-dt * 16))
                var next = uniforms.notch + (notchTarget - uniforms.notch) * k
                if simd_reduce_max(abs(notchTarget - next)) < 0.25 { next = notchTarget }
                uniforms.notch = next
            }
        }

        let width = edgeWidth * Float(0.55 + 0.45 * min(1, max(0.2, intensity))) * Float(0.85 + 0.9 * frame.bloom)
        uniforms.glow = SIMD4(width, Float(brightness), Float((frame.sparkle * 64).rounded() / 64), width * 4.3 + 2)
        let base = frame.colorPosition - frame.wavePhase
        let winding = Float(min(1, max(0, (frame.spread - 0.6) / 0.3)))
        uniforms.flow = SIMD4(Float(base - floor(base)), Float(0.55 * frame.spread), Float(flowPhase), winding)
        let colors = palette.colors
        uniforms.misc.x = Float(colors.count)
        uniforms.c0 = Self.vector(colors, 0)
        uniforms.c1 = Self.vector(colors, 1)
        uniforms.c2 = Self.vector(colors, 2)
        uniforms.c3 = Self.vector(colors, 3)

        guard uniforms != lastDrawn else { return }
        draw(clearOnly: false)
    }

    private static func vector(_ colors: [AmbientLightPalette.RGB], _ index: Int) -> SIMD4<Float> {
        let c = colors[index % max(1, colors.count)]
        return SIMD4(Float(c.r), Float(c.g), Float(c.b), 1)
    }

    private func draw(clearOnly: Bool) {
        if let older = inFlight[slot], older.status != .completed, older.status != .error { return }
        guard let drawable = layer.nextDrawable(),
              let commands = gpu.queue.makeCommandBuffer() else { return }
        pass.colorAttachments[0].texture = drawable.texture
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else {
            pass.colorAttachments[0].texture = nil
            return
        }
        if !clearOnly {
            encoder.setRenderPipelineState(gpu.pipeline)
            let length = MemoryLayout<AmbientEdgeUniforms>.stride
            encoder.setVertexBytes(&uniforms, length: length, index: 0)
            encoder.setFragmentBytes(&uniforms, length: length, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 24)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
        pass.colorAttachments[0].texture = nil
        inFlight[slot] = commands
        slot = (slot + 1) % inFlight.count
        if clearOnly {
            clearedDark = true
            lastDrawn = nil
        } else {
            lastDrawn = uniforms
        }
    }
}
