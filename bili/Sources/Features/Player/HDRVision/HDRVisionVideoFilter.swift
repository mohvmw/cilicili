import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import os

/// HDR 视界视频滤镜。
///
/// 把脚本的 WGSL 管线（去色带 → CAS 锐化 → 曝光 → BT.2446a/幂函数映射 → OKLab 饱和度）
/// 逐句移植为 Core Image Metal 内核，逐帧应用到播放画面上。
///
/// 显示路线：`AVPlayerItemVideoOutput` 拉帧 + Metal 层显示
///（`HDRVisionVideoOutputDisplay`）。视频合成路线已死：HLS 桥接素材在
/// `.tracks` 里报 0 条轨道，合成引擎建不出自定义合成器——旧的
/// `AVMutableVideoComposition` 和新的 `AVVideoComposition.Configuration`
/// 都试过，合成器一直“未建”（实测 2026-11-18）。所以不再挂 videoComposition，
/// 改由引擎复用已有的 videoOutput 拉帧，处理后用 Metal 层盖在播放面上。
/// 这是 iOS 上与 mpv `glsl-shaders` 对应的做法中唯一能走通的一条。
///
/// 注意（与 PiliPlus 的 GLSL 移植一样）：
/// - 内核按显示参考值运算，与脚本的纹理值含义一致；SDR 源（BT.709）上效果与脚本一致。
/// - 输出可能超过 1.0（BT.2446a 上限 5.0），能否在 XDR 屏上呈现为真 HDR 亮度，
///   取决于播放层是否保留扩展范围，需真机验证；至少在 SDR 内是同款增强。
enum HDRVisionVideoFilter {
    // MARK: - 内核（构建期编译的 stitchable 内核，从 default.metallib 加载）

    /// 从构建期编译好的 `default.metallib` 加载 stitchable 内核。
    ///
    /// 内核源码在同目录的 `HDRVisionKernel.metal`。注意它必须是**通用内核**
    ///（`CIKernel`，首参 `coreimage::sampler_h`）：stitchable 形式下颜色内核
    /// 的首参只能是单个像素值（`sample_t`/`sample_h`），无法采样邻域；而
    /// deband/CAS 必须采邻域。构建日志已证实：`sample()`/`samplerTransform()`
    /// 这两个自由函数只接受 `sampler`（`sample_t` 传进去编译不过），所以
    /// `sample_t` + `destination` 的颜色内核写法走不通。通用内核用
    /// `apply(extent:roiCallback:arguments:)`，ROI 回调把输入区域向外扩 32px
    ///（deband/CAS 最远采 32px），输入先 `clampedToExtent()`，边缘才不会变黑。
    /// 工程需在 Metal 链接参数里加 `-framework CoreImage`
    ///（见 project.pbxproj 的 MTLLINKER_FLAGS），否则链接器找不到
    /// Core Image 的 Metal 符号。
    /// 运行时编译（`kernels(withMetalString:)`）在真机上以 CIKernel error 13
    /// 失败且无详细信息，改走构建期编译后，Metal 源码错误会直接出现在构建日志里。
    /// 不加 private：视频输出显示（HDRVisionVideoOutputDisplay）要读它。
    /// nonisolated：显示的拉帧回调跑在主线程，但内核加载与逐帧应用
    /// 都不碰 @MainActor 的状态（加载失败只写锁保护的 _kernelLoadError，
    /// 日志用的是 nonisolated 的 PlayerMetricsLog.logger）。
    nonisolated static let kernel: CIKernel? = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib") else {
            setKernelLoadError("未找到 default.metallib（Metal 库未打包）")
            PlayerMetricsLog.logger.error("hdrVisionKernel load failed: default.metallib not found")
            return nil
        }
        guard let data = try? Data(contentsOf: url) else {
            setKernelLoadError("读取 default.metallib 失败")
            PlayerMetricsLog.logger.error("hdrVisionKernel load failed: cannot read default.metallib")
            return nil
        }
        do {
            return try CIKernel(functionName: "hdrVisionKernel", fromMetalLibraryData: data)
        } catch {
            // 注意：基类 CIKernel 的这个构造器是 throwing 且非 failable，
            // 与 CIColorKernel 的 failable 构造器不同，不能用 guard let。
            setKernelLoadError("加载 hdrVisionKernel 失败：\(error.localizedDescription)")
            PlayerMetricsLog.logger.error("hdrVisionKernel load failed: \(error.localizedDescription)")
            return nil
        }
    }()

    // MARK: - 诊断状态（设置页读取）

    private static let statusLock = NSLock()
    private static var _lastApplyStatus = "未调用"
    private static var _framesProcessed = 0
    private static var _framesPassedThrough = 0
    /// 显示层最近一次渲染失败的原因（Metal 层拿不到 drawable、尺寸为 0 等）。
    /// 为 nil 表示最近一次渲染成功。显示层诊断用：已处理帧涨但画面不变时，
    /// 看这里就知道帧到底上没上屏。
    private static var _displayLastError: String?

    /// 显示层最近一次渲染失败的原因，nil 表示最近一次渲染成功。
    static var displayLastError: String? { statusLock.withLock { _displayLastError } }

    /// 显示层（HDRVisionDisplayView）设置最近一次渲染的结果。
    /// nonisolated：只写锁保护的变量。
    nonisolated static func setDisplayLastError(_ message: String?) {
        statusLock.withLock { _displayLastError = message }
    }

    /// Metal 内核是否加载成功（从 default.metallib）。首次读取会触发加载。
    static var kernelCompiled: Bool { kernel != nil }

    /// 最近一次应用的结果：未调用 / 等待就绪… / 显示中（视频输出） /
    /// 开关已关闭 / HDR 源已跳过 / 纯音频已跳过 / 内核未加载：…。
    static var lastApplyStatus: String { statusLock.withLock { _lastApplyStatus } }

    /// 上次应用是否失败或还没显示出来（可重试）。开关关闭 / 显示中不算。
    /// 引擎在 item ready 后用它决定是否重试。
    static var lastApplyFailed: Bool {
        statusLock.withLock {
            _lastApplyStatus.hasPrefix("内核未加载")
                || _lastApplyStatus.hasPrefix("等待就绪")
        }
    }

    /// 逐帧回调里内核成功处理 / 原样直通的帧数。直通一直涨而处理帧为 0，说明每帧都没进内核。
    static var frameCounts: (processed: Int, passedThrough: Int) {
        statusLock.withLock { (_framesProcessed, _framesPassedThrough) }
    }

    /// 自定义合成器逐帧调用：内核成功处理了一帧。
    /// nonisolated：合成器跑在渲染队列上；计数只碰锁保护的变量。
    nonisolated static func noteFrameProcessed() {
        statusLock.withLock { _framesProcessed += 1 }
    }

    /// 自定义合成器逐帧调用：这一帧没进内核（无帧 / 内核失败），原样直通。
    /// nonisolated：同上。
    nonisolated static func noteFramePassedThrough() {
        statusLock.withLock { _framesPassedThrough += 1 }
    }

    /// 引擎（视频输出显示的开关逻辑）设置最近一次应用的结果。只写锁保护的变量。
    static func setLastApplyStatus(_ status: String) {
        statusLock.withLock { _lastApplyStatus = status }
    }

    private static var _kernelLoadError: String?

    /// 最近一次内核加载失败的原因（Metal 编译错误信息），成功时为 nil。
    static var kernelLoadError: String? { statusLock.withLock { _kernelLoadError } }

    /// nonisolated：内核的 nonisolated 初始化闭包里调用它；只写锁保护的变量。
    nonisolated private static func setKernelLoadError(_ message: String) {
        statusLock.withLock { _kernelLoadError = message }
    }

    // MARK: - 逐帧应用

    /// 不加 private：视频输出显示（HDRVisionVideoOutputDisplay）逐帧调用它。
    /// nonisolated：只做纯计算 + CIKernel.apply。
    nonisolated static func applyKernel(
        _ kernel: CIKernel,
        to image: CIImage,
        settings: HDRVisionSettings
    ) -> CIImage? {
        let uniforms = computeUniforms(settings)
        // 边缘像素复制扩展：deband/CAS 要采 32px 外的邻域，越界采样才不会变黑。
        let input = image.clampedToExtent()
        var arguments: [Any] = [input]
        arguments.append(contentsOf: uniforms.map { NSNumber(value: $0) })
        return kernel.apply(
            extent: image.extent,
            roiCallback: { _, rect in rect.insetBy(dx: -32, dy: -32) },
            arguments: arguments
        )
    }

    /// 与脚本 `computeUniformData` 相同的 uniform 计算（32 个 float 的子集，
    /// 只保留内核实际用到的 19 个；顺序与内核参数声明一致）。
    /// nonisolated：applyKernel（nonisolated）里调用它；纯计算。
    nonisolated private static func computeUniforms(_ settings: HDRVisionSettings) -> [Float] {
        let isBT = settings.mappingMode == .bt2446a
        let exposureMultiplier = Float(pow(2.0, settings.activeExposure))
        let saturation = Float(settings.activeSaturation)
        let skipSaturation: Float = abs(settings.activeSaturation - 1.0) < 0.001 ? 1 : 0
        let peak = Float(settings.activePeakBrightness)
        let maxL = max(settings.activePeakBrightness, 1.0) * 100
        let pHDR = Float(1.0 + 32.0 * pow(maxL / 10000.0, 1.0 / 2.4))
        let logPHDR = Float(log(Double(pHDR)))
        let skipBoost: Float = !isBT && settings.powerMaxBoost <= 1.001 ? 1 : 0
        let skipShadow: Float = !isBT && settings.powerShadowCrush < 0.001 ? 1 : 0
        return [
            exposureMultiplier,
            saturation,
            skipSaturation,
            peak,
            isBT ? 1 : 0,
            Float(settings.btBoost),
            pHDR,
            logPHDR,
            isBT ? Float(settings.btMidToneLift) : 0,
            Float(settings.powerBrightnessThreshold),
            Float(settings.powerMaxBoost),
            Float(settings.powerShadowThreshold),
            Float(settings.powerShadowCrush),
            skipBoost,
            skipShadow,
            settings.debandEnabled ? 1 : 0,
            settings.debandEnabled ? Float(settings.debandThreshold) : 0,
            settings.sharpenEnabled ? 1 : 0,
            Float(settings.sharpenStrength),
        ]
    }
}
