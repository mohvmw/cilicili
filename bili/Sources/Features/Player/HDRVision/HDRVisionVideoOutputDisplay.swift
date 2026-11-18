import AVFoundation
import CoreImage
import Metal
import UIKit

/// HDR 视界逐帧显示层：用 CAMetalLayer + CIContext 把处理后的画面画出来。
///
/// 盖在播放面的 AVPlayerLayer 之上（不透明），HDR 开时显示处理帧，关时隐藏。
/// 画面按视频尺寸与 videoGravity 做适配（默认 aspect fit，留黑边），与
/// AVPlayerLayer 的显示一致。
final class HDRVisionDisplayView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private let metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
    private lazy var commandQueue: MTLCommandQueue? = metalDevice?.makeCommandQueue()
    private lazy var ciContext: CIContext? = metalDevice.map { CIContext(mtlDevice: $0) }

    private var videoSize: CGSize = .zero
    private var videoGravity: AVLayerVideoGravity = .resizeAspect

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        // CIContext 要往纹理里写，framebufferOnly 关掉更稳妥。
        metalLayer.framebufferOnly = false
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.contentsScale = UIScreen.main.scale
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 设置视频尺寸与重力（用于画面适配）。
    func configure(videoSize: CGSize, gravity: AVLayerVideoGravity) {
        self.videoSize = videoSize
        self.videoGravity = gravity
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = contentScaleFactor > 0 ? contentScaleFactor : UIScreen.main.scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    /// 把处理后的画面画到 Metal 层上。非主线程调用无效（由 DisplayLink 在主线程调）。
    func display(image: CIImage) {
        guard let commandQueue, let ciContext else { return }
        guard let drawable = metalLayer.nextDrawable() else { return }
        let texture = drawable.texture
        let size = metalLayer.drawableSize
        guard size.width > 0, size.height > 0 else { return }
        let bounds = CGRect(origin: .zero, size: CGSize(width: size.width, height: size.height))
        let destRect = Self.destinationRect(videoSize: videoSize, in: bounds.size, gravity: videoGravity)
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // 先铺黑底（letterbox 黑边），再把处理帧画到目标区域。
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: bounds)
        ciContext.render(black, to: texture, commandBuffer: commandBuffer, bounds: bounds, colorSpace: colorSpace)
        ciContext.render(image, to: texture, commandBuffer: commandBuffer, bounds: destRect, colorSpace: colorSpace)
        commandBuffer.present(drawable)
        commandBuffer.commit()
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

/// HDR 视界视频输出显示：用 AVPlayerItemVideoOutput 拉帧，内核处理后用 Metal 层显示。
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

    /// 更新画面重力。
    func setVideoGravity(_ gravity: AVLayerVideoGravity) {
        videoGravity = gravity
        displayView.configure(videoSize: videoSize, gravity: gravity)
    }

    /// 开/关 HDR 显示。开：启动 DisplayLink 拉帧；关：停掉并隐藏显示层。
    func setActive(_ active: Bool, videoSize: CGSize = .zero, gravity: AVLayerVideoGravity = .resizeAspect) {
        self.videoSize = videoSize
        self.videoGravity = gravity
        displayView.configure(videoSize: videoSize, gravity: gravity)
        if active {
            guard !isActive else { return }
            isActive = true
            displayView.isHidden = false
            lastDisplayedItemTime = nil
            let link = CADisplayLink(target: self, selector: #selector(tickDisplayLink))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else {
            guard isActive else {
                displayView.isHidden = true
                return
            }
            isActive = false
            displayLink?.invalidate()
            displayLink = nil
            lastDisplayedItemTime = nil
            displayView.isHidden = true
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
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        if let kernel = HDRVisionVideoFilter.kernel,
           let outputImage = HDRVisionVideoFilter.applyKernel(kernel, to: sourceImage, settings: settings) {
            displayView.display(image: outputImage)
            HDRVisionVideoFilter.noteFrameProcessed()
        } else {
            // 内核没加载或应用失败：原帧直通显示，画面不断。
            displayView.display(image: sourceImage)
            HDRVisionVideoFilter.noteFramePassedThrough()
        }
    }
}
