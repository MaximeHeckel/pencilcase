import AppKit
import MetalKit
import CoreVideo
import simd
import QuartzCore

@MainActor
final class LoupeRenderer: NSObject, MTKViewDelegate {
    let view: MTKView
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var cache: CVMetalTextureCache?
    private var buffer: CVPixelBuffer?
    private var image: CVMetalTexture?
    private let inFlight = DispatchSemaphore(value: 1)
    private let renderQueue = DispatchQueue(label: "PencilCase.loupe.render", qos: .userInteractive)
    private var needsFrame = true
    var centerUV = SIMD2<Float>(0.5, 0.5)
    var inverseScreenSize = SIMD2<Float>(1 / 1920, 1 / 1080)
    var zoom: Float = 2
    static let diameter: CGFloat = 216

    init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else {
            throw NSError(domain: "Loupe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal is unavailable on this Mac."])
        }
        self.queue = queue
        view = MTKView(frame: .zero, device: device)
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "loupeVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "loupeFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        super.init()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.layer?.isOpaque = false
        view.isPaused = true
        view.preferredFramesPerSecond = 120
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = true
        view.delegate = self
    }

    func receive(_ pixelBuffer: CVPixelBuffer) {
        guard let cache else { return }
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &texture)
        guard status == kCVReturnSuccess else { return }
        buffer = pixelBuffer
        image = texture
        requestDraw()
    }

    func clear() {
        buffer = nil
        image = nil
        if let cache { CVMetalTextureCacheFlush(cache, 0) }
        requestDraw()
    }

    func setActive(_ active: Bool) {
        view.isPaused = !active
        if active { requestDraw() }
    }

    /// Input and capture only invalidate. The display callback submits the latest state.
    func requestDraw() { needsFrame = true }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { requestDraw() }

    func draw(in view: MTKView) {
        guard needsFrame, let layer = view.layer as? CAMetalLayer,
              inFlight.wait(timeout: .now()) == .success else { return }

        needsFrame = false
        let job = RenderJob(layer: layer, queue: queue, pipeline: pipeline,
                            buffer: buffer, image: image,
                            uniforms: Uniforms(center: centerUV, inverseScreen: inverseScreenSize,
                                               diameter: Float(Self.diameter), zoom: zoom))
        let semaphore = inFlight

        // nextDrawable can block while the compositor owns the surfaces. Never
        // acquire it on AppKit's input thread, and never enqueue a backlog of jobs.
        renderQueue.async { [weak self] in
            guard job.render(completed: { semaphore.signal() }) else {
                semaphore.signal()
                Task { @MainActor [weak self] in self?.requestDraw() }
                return
            }
        }
    }

    // Immutable job snapshot. Only the serial render queue encodes commands;
    // captured IOSurface references are retained until the GPU completes.
    private nonisolated struct RenderJob: @unchecked Sendable {
        let layer: CAMetalLayer
        let queue: MTLCommandQueue
        let pipeline: MTLRenderPipelineState
        let buffer: CVPixelBuffer?
        let image: CVMetalTexture?
        let uniforms: Uniforms

        nonisolated func render(completed: @escaping @Sendable () -> Void) -> Bool {
            autoreleasepool {
                guard let drawable = layer.nextDrawable(),
                      let command = queue.makeCommandBuffer() else { return false }

                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = drawable.texture
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }

                if let image, let texture = CVMetalTextureGetTexture(image) {
                    var values = uniforms
                    encoder.setRenderPipelineState(pipeline)
                    encoder.setFragmentTexture(texture, index: 0)
                    encoder.setFragmentBytes(&values, length: MemoryLayout<Uniforms>.stride, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }

                encoder.endEncoding()
                command.present(drawable)
                command.addCompletedHandler { [self] _ in
                    withExtendedLifetime(self) {}
                    completed()
                }
                command.commit()
                return true
            }
        }
    }

    private nonisolated struct Uniforms {
        var center: SIMD2<Float>
        var inverseScreen: SIMD2<Float>
        var diameter: Float
        var zoom: Float
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct V { float4 position [[position]]; float2 uv; };
    struct U { float2 center; float2 inverseScreen; float diameter; float zoom; };
    vertex V loupeVertex(uint id [[vertex_id]]) {
        float2 p = id == 0 ? float2(-1,-1) : (id == 1 ? float2(3,-1) : float2(-1,3));
        V v; v.position = float4(p,0,1); v.uv = float2((p.x+1)*0.5, (1-p.y)*0.5); return v;
    }
    fragment float4 loupeFragment(V v [[stage_in]], texture2d<float> source [[texture(0)]], constant U &u [[buffer(0)]]) {
        constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);
        float2 p = (v.uv - 0.5) * 2;
        float r = length(p);
        // One output-pixel transition at any backing scale, rather than
        // a fixed normalized band that changes width with resolution.
        float edgeAA = max(fwidth(r), 0.00001);
        float alpha = 1 - smoothstep(1.0 - edgeAA, 1.0, r);
        if (alpha <= 0) return float4(0);
        // Confine refraction and RGB dispersion to the outer 12% of the radius.
        float rim = pow(smoothstep(0.88, 1.0, r), 2.0);
        float2 offset = p * (u.diameter * 0.5 / u.zoom) * (1 - 0.11 * rim);
        float2 uv = u.center + offset * u.inverseScreen;
        if (any(uv < 0) || any(uv > 1)) return float4(float3(0.12) * alpha, alpha);
        float2 split = p / max(r, 0.001) * (0.8 * rim / u.zoom) * u.inverseScreen;
        float3 color;
        color.r = source.sample(linearSampler, uv + split).r;
        color.g = source.sample(linearSampler, uv).g;
        color.b = source.sample(linearSampler, uv - split).b;
        float edge = smoothstep(0.94, 1.0, r);
        float2 normal = p / max(r, 0.001);
        float light = saturate(dot(normal, normalize(float2(-0.6,-0.8))));
        color *= 1 - edge * 0.10;

        // Fixed studio-like reflections describe the curved lens without washing
        // out its inspection area or requiring another texture/render pass.
        float edgeMask = smoothstep(0.85, 0.91, r);
        float upperArc = pow(light, 4.0);
        float oppositeArc = pow(saturate(dot(normal, normalize(float2(0.65,0.76)))), 12.0);
        float softReflection = exp(-pow((r - 0.925) / 0.032, 2.0)) * upperArc * 0.16;
        float crispReflection = exp(-pow((r - 0.972) / 0.010, 2.0)) * upperArc * 0.48;
        float lowerGlint = exp(-pow((r - 0.965) / 0.012, 2.0)) * oppositeArc * 0.24;
        float reflection = edgeMask * (softReflection + crispReflection + lowerGlint);
        color = mix(color, float3(1.0), saturate(reflection + edge * light * 0.12));
        return float4(color * alpha, alpha);
    }
    """
}
