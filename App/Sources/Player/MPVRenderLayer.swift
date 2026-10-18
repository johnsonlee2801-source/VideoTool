import AppKit
import Libmpv
import OpenGL.GL3
import QuartzCore

/// CAOpenGLLayer that mpv renders into through the OpenGL render API.
/// Same approach as IINA and yattee on macOS; the mpv cocoa backend has no
/// window embedding, so the render API is the only way to draw into our view.
///
/// Ownership: create and tear down through `PlaybackSession`. `renderLock`
/// is held for the whole of every render and for teardown, so the render
/// context can never be freed while a frame is being drawn.
final class MPVRenderLayer: CAOpenGLLayer {
    private weak var engine: MPVEngine?
    private var renderContext: OpaquePointer?
    private var cglPixelFormat: CGLPixelFormatObj?
    private var cglContext: CGLContextObj?
    private let renderLock = NSLock()
    private var isTornDown = false
    private var loggedRenderFailure = false
    /// Core Animation makes shadow copies through init(layer:). They must never
    /// touch the live mpv / GL resources, which belong to the original only.
    private let ownsResources: Bool

    init(engine: MPVEngine) {
        self.engine = engine
        ownsResources = true
        super.init()
        // Create the GL context and mpv's render context right away. CAOpenGLLayer
        // would otherwise ask for them on its first draw, which happens after the
        // window is shown; a file loaded at launch would then hit
        // "No render context set" and play nothing (smoke test 2026-10-18).
        if let pf = Self.choosePixelFormat() {
            var ctx: CGLContextObj?
            if CGLCreateContext(pf, nil, &ctx) == kCGLNoError, let ctx {
                cglPixelFormat = pf
                adopt(ctx)
            } else {
                CGLReleasePixelFormat(pf)
            }
        }
        isAsynchronous = false
        isOpaque = true
        backgroundColor = NSColor.black.cgColor
        needsDisplayOnBoundsChange = true
        autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    }

    override init(layer: Any) {
        ownsResources = false
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if ownsResources { teardown() }
    }

    private var isTornDownLocked: Bool {
        renderLock.lock(); defer { renderLock.unlock() }
        return isTornDown
    }

    /// True once mpv has a render context; files must not load before this.
    var isReady: Bool {
        renderLock.lock(); defer { renderLock.unlock() }
        return renderContext != nil
    }

    // MARK: GL setup

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        if let pf = cglPixelFormat { return CGLRetainPixelFormat(pf) }
        return Self.choosePixelFormat() ?? super.copyCGLPixelFormat(forDisplayMask: mask)
    }

    private static func choosePixelFormat() -> CGLPixelFormatObj? {
        let attributeSets: [[CGLPixelFormatAttribute]] = [
            [kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue),
             kCGLPFAAccelerated, kCGLPFADoubleBuffer, kCGLPFAAllowOfflineRenderers, _CGLPixelFormatAttribute(rawValue: 0)],
            [kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue),
             kCGLPFADoubleBuffer, kCGLPFAAllowOfflineRenderers, _CGLPixelFormatAttribute(rawValue: 0)],
        ]
        for attrs in attributeSets {
            var pf: CGLPixelFormatObj?
            var count: GLint = 0
            if CGLChoosePixelFormat(attrs, &pf, &count) == kCGLNoError, let pf { return pf }
        }
        return nil
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        if ownsResources, cglContext == nil, !isTornDownLocked {
            adopt(super.copyCGLContext(forPixelFormat: pf))
        }
        guard let ctx = cglContext else { return super.copyCGLContext(forPixelFormat: pf) }
        if ownsResources { withCurrentContext(ctx) { createRenderContextIfNeeded() } }  // retry if it failed before
        return CGLRetainContext(ctx)
    }

    /// Single place that configures a GL context and attaches mpv to it.
    private func adopt(_ ctx: CGLContextObj) {
        var swap: GLint = 1
        CGLSetParameter(ctx, kCGLCPSwapInterval, &swap)
        CGLEnable(ctx, kCGLCEMPEngine)
        cglContext = ctx
        withCurrentContext(ctx) { createRenderContextIfNeeded() }
    }

    /// Makes `ctx` current for `body`, then restores whatever was current before.
    private func withCurrentContext(_ ctx: CGLContextObj, _ body: () -> Void) {
        let previous = CGLGetCurrentContext()
        CGLSetCurrentContext(ctx)
        defer { CGLSetCurrentContext(previous) }
        body()
    }

    private func createRenderContextIfNeeded() {
        renderLock.lock(); defer { renderLock.unlock() }
        guard !isTornDown, renderContext == nil, let engine else { return }

        var initParams = mpv_opengl_init_params(get_proc_address: { _, name in
            guard let name,
                  let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString) else { return nil }
            return CFBundleGetFunctionPointerForName(bundle, String(cString: name) as CFString)
        }, get_proc_address_ctx: nil)

        let apiType = strdup(MPV_RENDER_API_TYPE_OPENGL)
        defer { free(apiType) }
        var ctx: OpaquePointer?
        let result: Int32 = engine.withHandle { handle in withUnsafeMutablePointer(to: &initParams) { initPtr in
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(apiType)),
                mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initPtr)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
            ]
            return params.withUnsafeMutableBufferPointer { buf in
                mpv_render_context_create(&ctx, handle, buf.baseAddress)
            }
        } } ?? MPV_ERROR_UNINITIALIZED.rawValue
        guard result >= 0, let ctx else {
            NSLog("mpv_render_context_create failed: %@ (will retry on next draw)", String(cString: mpv_error_string(result)))
            return
        }
        renderContext = ctx
        mpv_render_context_set_update_callback(ctx, { userdata in
            guard let userdata else { return }
            Unmanaged<MPVRenderLayer>.fromOpaque(userdata).takeUnretainedValue().frameAvailable()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    private func frameAvailable() {
        DispatchQueue.main.async { [weak self] in self?.setNeedsDisplay() }
    }

    // MARK: drawing

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        true
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        if ownsResources, !isReady { createRenderContextIfNeeded() }

        let width = Int32((bounds.width * contentsScale).rounded())
        let height = Int32((bounds.height * contentsScale).rounded())

        renderLock.lock()
        defer { renderLock.unlock() }
        guard ownsResources, let rc = renderContext, width > 0, height > 0 else {
            glClearColor(0, 0, 0, 1)
            glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
            super.draw(inCGLContext: ctx, pixelFormat: pf, forLayerTime: t, displayTime: ts)
            return
        }

        var boundFBO: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &boundFBO)
        var fbo = mpv_opengl_fbo(fbo: Int32(boundFBO), w: width, h: height, internal_format: 0)
        var flipY: Int32 = 1
        let result: Int32 = withUnsafeMutablePointer(to: &fbo) { fboPtr in
            withUnsafeMutablePointer(to: &flipY) { flipPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                return params.withUnsafeMutableBufferPointer { buf in
                    mpv_render_context_render(rc, buf.baseAddress)
                }
            }
        }
        if result < 0, !loggedRenderFailure {
            loggedRenderFailure = true            // log once, not every frame
            NSLog("mpv_render_context_render failed: %@", String(cString: mpv_error_string(result)))
        }
        glFlush()
        super.draw(inCGLContext: ctx, pixelFormat: pf, forLayerTime: t, displayTime: ts)
    }

    // MARK: teardown

    /// Frees the render context and the GL objects. Idempotent. Must run before
    /// `MPVEngine.shutdown()`; `PlaybackSession` guarantees the order.
    func teardown() {
        guard ownsResources else { return }
        renderLock.lock(); defer { renderLock.unlock() }
        guard !isTornDown else { return }
        isTornDown = true
        if let rc = renderContext {
            renderContext = nil
            mpv_render_context_set_update_callback(rc, nil, nil)
            if let cglContext {
                withCurrentContext(cglContext) { mpv_render_context_free(rc) }
            } else {
                mpv_render_context_free(rc)
            }
        }
        if let cglContext { CGLReleaseContext(cglContext); self.cglContext = nil }
        if let cglPixelFormat { CGLReleasePixelFormat(cglPixelFormat); self.cglPixelFormat = nil }
    }
}
