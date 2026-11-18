import AVFoundation
import CoreVideo
import Metal
import UIKit

/// HDR 视界逐帧显示层：用 CAMetalLayer + Metal 计算核把处理后的画面画出来。
///
/// 盖在播放面的 AVPlayerLayer 之上（不透明），HDR 开时显示处理帧，关时隐藏。
/// 画面按播放层实际的 videoRect 定位（与关 HDR 时播放层的位置一致），
/// 取不到 videoRect 时按视频尺寸与 videoGravity 自己算。
///
/// 显示路径是 Metal 计算核（HDRVisionCompute.metal），不是 Core Image：
/// CI 内核 + CIContext 在显示上有三个解不掉的问题——浮点纹理 + EDR 时
/// 色彩空间对不上（画面泛白）、CIContext.render 的 bounds 缩放不可靠
///（画面总被放大）、超 1.0 的值可能被截掉（亮度不变）。计算核直接读写
/// 纹理，色彩、几何、亮度全部自己控制。输入是引擎 videoOutput 给的
/// 32BGRA 像素缓冲（已是 RGB），经 CVMetalTextureCache 转纹理；
/// 输出直接写 drawable 的 rgba16Float 纹理（EDR），超 1.0 的高光保留。
final class HDRVisionDisplayView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private let metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
    private lazy var commandQueue: MTLCommandQueue? = metalDevice?.makeCommandQueue()
    /// 把 32BGRA 像素缓冲转成 Metal 纹理（CVMetalTextureCache）。
    private lazy var textureCache: CVMetalTextureCache? = {
        guard let metalDevice else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        return cache
    }()
    /// 计算核管线（HDRVisionCompute.metal 里的 hdrVisionCompute，编进 default.metallib）。
    private lazy var computePipeline: MTLComputePipelineState? = {
        guard let metalDevice,
              let library = metalDevice.makeDefaultLibrary(),
              let function = library.makeFunction(name: "hdrVisionCompute") else { return nil }
        return try? metalDevice.makeComputePipelineState(function: function)
    }()

    private var videoSize: CGSize = .zero
    private var videoGravity: AVLayerVideoGravity = .resizeAspect
    /// 播放层实际的视频矩形（点坐标，相对显示层 bounds），由引擎从
    /// `AVPlayerLayer.videoRect` 取来。优先用它定位画面（与关 HDR 时
    /// 播放层显示的位置完全一致）；取不到时才按 videoSize/gravity 自己算。
    private var videoRect: CGRect = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        // 计算核要往 drawable 纹理里写，framebufferOnly 关掉更稳妥。
        metalLayer.framebufferOnly = false
        // EDR 显示（参考 MPlayKit 管线）：BT.2446a 的输出会超过 1.0（峰值
        // 1.7 左右），8 位 BGRA 会把超 1.0 的高光截到 1.0，永远看不到 HDR
        // 亮度。改用 16 位浮点纹理 + wantsExtendedDynamicRangeContent，
        // 超 1.0 的值才能在 XDR 屏上真正亮起来（iOS 按屏幕实际峰值显示）。
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.wantsExtendedDynamicRangeContent = true
        // 色彩空间必须显式设成扩展 sRGB：计算核输出的是 gamma 编码的
        // sRGB 值（可超 1.0）。若 colorspace 留空，系统会把纹理值按线性
        // 理解，中间调全被抬亮，整幅画面泛白。设成扩展 sRGB 后，系统按
        // sRGB 的 EOTF 解码，超 1.0 的部分才作为 EDR 高光正常显示。
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedSRGB)
        metalLayer.contentsScale = UIScreen.main.scale
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 计算核是否就绪（设备 + 管线）。setActive 开显示前先查它：
    /// 若计算核建不起来就不显示，避免黑层盖住播放层。
    var isComputeReady: Bool {
        metalDevice != nil && computePipeline != nil
    }

    /// 设置视频尺寸与重力（用于画面适配的兜底计算）。
    func configure(videoSize: CGSize, gravity: AVLayerVideoGravity) {
        self.videoSize = videoSize
        self.videoGravity = gravity
    }

    /// 设置播放层实际的视频矩形（点坐标）。由引擎在布局后从 playerLayer 取来。
    func setVideoRect(_ rect: CGRect) {
        videoRect = rect
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = contentScaleFactor > 0 ? contentScaleFactor : UIScreen.main.scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    /// 用计算核把一帧像素缓冲处理后画到 Metal 层上。非主线程调用无效
    ///（由 DisplayLink 在主线程调）。返回是否真的把一帧交给了显示层
    ///（拿到 drawable 并提交）。注意：调用方不要只按“调过 display”计数——
    /// 拿不到 drawable 或计算核建不起来时这里会提前返回，帧并没有上屏；
    /// 只有返回 true 才算真正显示了一帧。
    @discardableResult
    func display(pixelBuffer: CVPixelBuffer) -> Bool {
        // 防御：布局回调还没跑过时 drawableSize 可能是 0，这里按当前 bounds 再算一次。
        let scale = contentScaleFactor > 0 ? contentScaleFactor : UIScreen.main.scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard let commandQueue, let computePipeline, let textureCache else {
            HDRVisionVideoFilter.setDisplayLastError("无 Metal 设备/计算管线")
            return false
        }
        guard let drawable = metalLayer.nextDrawable() else {
            HDRVisionVideoFilter.setDisplayLastError("拿不到 drawable（显示层未进窗口或尺寸为 0）")
            return false
        }
        let dstTexture = drawable.texture
        let dstSize = metalLayer.drawableSize
        guard dstSize.width > 0, dstSize.height > 0 else {
            HDRVisionVideoFilter.setDisplayLastError("drawable 尺寸为 0")
            return false
        }
        // 源纹理：32BGRA 像素缓冲（单平面）→ bgra8Unorm 纹理。
        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard srcWidth > 0, srcHeight > 0 else {
            HDRVisionVideoFilter.setDisplayLastError("像素缓冲尺寸为 0")
            return false
        }
        var srcMetalTexture: CVMetalTexture?
        let texStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .bgra8Unorm, srcWidth, srcHeight, 0, &srcMetalTexture
        )
        guard texStatus == kCVReturnSuccess,
              let srcMetalTexture,
              let srcTexture = CVMetalTextureGetTexture(srcMetalTexture) else {
            HDRVisionVideoFilter.setDisplayLastError("像素缓冲转纹理失败")
            return false
        }
        // 目标矩形（像素坐标）：优先用播放层实际的 videoRect（点坐标→像素坐标），
        // 与关 HDR 时播放层的位置完全一致；取不到时按尺寸/重力自己算。
        let dstBounds = CGRect(origin: .zero, size: CGSize(width: dstSize.width, height: dstSize.height))
        let destRect: CGRect
        if videoRect.width > 0, videoRect.height > 0, self.bounds.width > 0 {
            let rectScale = dstSize.width / self.bounds.width
            destRect = videoRect.applying(CGAffineTransform(scaleX: rectScale, y: rectScale))
        } else {
            destRect = Self.destinationRect(videoSize: videoSize, in: dstBounds.size, gravity: videoGravity)
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            HDRVisionVideoFilter.setDisplayLastError("建命令缓冲/编码器失败")
            return false
        }
        // Uniform（19 个 float，与计算核 HDRVisionComputeUniforms 顺序一致）
        // 与几何参数（目标矩形/源尺寸/目标尺寸）传给计算核。
        let settings = HDRVisionSettingsBox.shared.settings
        var uniforms = HDRVisionVideoFilter.computeUniforms(settings)
        var params = HDRVisionComputeParams(
            destOrigin: SIMD2<Float>(Float(destRect.origin.x), Float(destRect.origin.y)),
            destSize: SIMD2<Float>(Float(destRect.width), Float(destRect.height)),
            srcSize: SIMD2<Float>(Float(srcWidth), Float(srcHeight)),
            dstSize: SIMD2<Float>(Float(dstSize.width), Float(dstSize.height))
        )
        encoder.setComputePipelineState(computePipeline)
        encoder.setTexture(srcTexture, index: 0)
        encoder.setTexture(dstTexture, index: 1)
        encoder.setBytes(&uniforms, length: uniforms.count * MemoryLayout<Float>.size, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<HDRVisionComputeParams>.size, index: 1)
        // 按目标纹理尺寸派发，16×16 线程组。
        let threadsPerGroup = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(
            width: (Int(dstSize.width) + 15) / 16,
            height: (Int(dstSize.height) + 15) / 16,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        HDRVisionVideoFilter.setDisplayLastError(nil)
        return true
    }

    /// 按 videoGravity 算画面在显示区里的目标矩形（像素坐标）。
    private static func destinationRect(videoSize: CGSize, in bounds: CGSize, gravity: AVLayerVideoGravity) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        switch gravity {
        case .resizeAspect:
            return AVMakeRect(aspectRatio: videoSize, insideRect: CGRect(origin: .zero, size: bounds))
        case .resizeAspectFill:
            let scale = max(bounds.width / videoSize.width, bounds.height / videoSize.height)
            let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
            return CGRect(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
        case .resize:
            return CGRect(origin: .zero, size: bounds)
        default:
            return AVMakeRect(aspectRatio: videoSize, insideRect: CGRect(origin: .zero, size: bounds))
        }
    }
}

/// 计算核几何参数（与 HDRVisionCompute.metal 里的 HDRVisionComputeParams 布局一致）。
/// 必须和 Metal 侧的 struct 字段顺序/类型一致（float2 × 4）。
private struct HDRVisionComputeParams {
    var destOrigin: SIMD2<Float>
    var destSize: SIMD2<Float>
    var srcSize: SIMD2<Float>
    var dstSize: SIMD2<Float>
}

/// HDR 视界视频输出显示：用 AVPlayerItemVideoOutput 拉帧，计算核处理后用 Metal 层显示。
///
/// 替代已死的视频合成路线（合成器建不出来）。拉帧复用引擎已有的 videoOutput
///（引擎为截图/帧时间挂载，HDR 直接复用，不另建输出）；显示层盖在播放面的
/// AVPlayerLayer 之上，HDR 开时显示处理帧，关时隐藏，恢复正常播放。
/// 帧率：DisplayLink 每屏刷新取一帧，30fps 视频同一帧会取到两次，用
/// itemTimeForDisplay 去重，只画新帧。
@MainActor
final class HDRVisionVideoOutputDisplay {
    /// 显示层：加到播放面上的 Metal 视图。
    let displayView = HDRVisionDisplayView()

    /// 拉帧用的视频输出由引擎提供（引擎已为截图挂载，HDR 复用）。
    private let videoOutputProvider: @MainActor () -> AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
    private var lastDisplayedItemTime: CMTime?
    private(set) var isActive = false
    private var videoSize: CGSize = .zero
    private var videoGravity: AVLayerVideoGravity = .resizeAspect

    init(videoOutputProvider: @escaping @MainActor () -> AVPlayerItemVideoOutput?) {
        self.videoOutputProvider = videoOutputProvider
    }

    // 注意：不写 deinit 停 DisplayLink——@MainActor 类的 deinit 是 nonisolated，
    // 不能碰主线程隔离的 displayLink。停泵统一走 setActive(false)（引擎在
    // detachSurface / 换项 / 关开关时都会调），DisplayLink 失效即解除对 self 的持有。

    /// 把显示层加到播放面（插到子视图最下层：盖住 AVPlayerLayer，但在其他浮层之下）。
    func attach(to surface: UIView) {
        if displayView.superview !== surface {
            displayView.removeFromSuperview()
            surface.insertSubview(displayView, at: 0)
        }
        displayView.frame = surface.bounds
        displayView.isHidden = !isActive
    }

    /// 从播放面移除显示层并停止拉帧。
    func detach() {
        setActive(false)
        displayView.removeFromSuperview()
    }

    /// 按当前布局更新显示层位置（填满播放面）。
    func layout(in surface: UIView) {
        displayView.frame = surface.bounds
    }

    /// 布局变化时更新显示层的视频矩形（播放层实际位置，点坐标）。
    func updateVideoRect(_ rect: CGRect) {
        displayView.setVideoRect(rect)
    }

    /// 更新画面重力。
    func setVideoGravity(_ gravity: AVLayerVideoGravity) {
        videoGravity = gravity
        displayView.configure(videoSize: videoSize, gravity: gravity)
    }

    /// 开/关 HDR 显示。开：启动 DisplayLink 拉帧；关：停掉并隐藏显示层。
    /// 计算核没就绪时不开（避免黑层盖住播放层），返回 false，由调用方看状态。
    @discardableResult
    func setActive(_ active: Bool, videoSize: CGSize = .zero, gravity: AVLayerVideoGravity = .resizeAspect) -> Bool {
        self.videoSize = videoSize
        self.videoGravity = gravity
        displayView.configure(videoSize: videoSize, gravity: gravity)
        if active {
            guard displayView.isComputeReady else {
                HDRVisionVideoFilter.setLastApplyStatus("计算核未加载")
                return false
            }
            guard !isActive else { return true }
            isActive = true
            displayView.isHidden = false
            // 提到最前面：防止播放层或其他子视图后加进来盖住显示层。
            displayView.superview?.bringSubviewToFront(displayView)
            lastDisplayedItemTime = nil
            let link = CADisplayLink(target: self, selector: #selector(tickDisplayLink))
            link.add(to: .main, forMode: .common)
            displayLink = link
            return true
        } else {
            guard isActive else {
                displayView.isHidden = true
                return true
            }
            isActive = false
            displayLink?.invalidate()
            displayLink = nil
            lastDisplayedItemTime = nil
            displayView.isHidden = true
            return true
        }
    }

    @objc private func tickDisplayLink() {
        guard isActive, let output = videoOutputProvider() else { return }
        // 显示层还没进窗口（播放面未挂载）时不拉帧，免得白做工。
        guard displayView.window != nil else { return }
        let hostTime = CACurrentMediaTime()
        let itemTime = output.itemTime(forHostTime: hostTime)
        var displayTime = CMTime.invalid
        guard let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime) else { return }
        // 去重：同一帧在 60Hz 刷新下会取到两次，只画新帧。
        if displayTime.isValid {
            if let last = lastDisplayedItemTime, last == displayTime { return }
            lastDisplayedItemTime = displayTime
        }
        let settings = HDRVisionSettingsBox.shared.settings
        guard settings.enabled else { return }
        // 计算核直接处理像素缓冲（不再走 Core Image 的 CIImage/CIKernel）。
        // 只有真的上屏才算处理帧；display 返回 false（没拿到 drawable、
        // 计算管线建不起来等）时不计数，免得数字涨了画面却没变、误导判断。
        if displayView.display(pixelBuffer: pixelBuffer) {
            HDRVisionVideoFilter.noteFrameProcessed()
        }
    }
}
