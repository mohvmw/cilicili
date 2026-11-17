import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import os

/// HDR 视界视频滤镜。
///
/// 把脚本的 WGSL 管线（去色带 → CAS 锐化 → 曝光 → BT.2446a/幂函数映射 → OKLab 饱和度）
/// 逐句移植为 Core Image Metal 内核，经手动建的 `AVMutableVideoComposition` +
/// 自定义合成器（`HDRVisionVideoCompositor`）挂到 `AVPlayerItem` 上。
/// 这是 iOS 上与 mpv `glsl-shaders` 对应的做法：AVPlayer 没有 shader 挂载点，
/// 视频合成是唯一能在不替换整个播放面的前提下逐帧处理画面的官方路径。
/// 不用基于素材的合成工厂，是因为 HLS 桥接素材在 `.tracks` 里报 0 条轨道，
/// 工厂建不出合成；手动建合成 + 自定义合成器不依赖素材轨道。
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
    /// 不加 private：自定义合成器（HDRVisionVideoCompositor）要读它。
    /// nonisolated：合成器跑在渲染队列（非主线程）上，内核加载与逐帧应用
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

    /// Metal 内核是否加载成功（从 default.metallib）。首次读取会触发加载。
    static var kernelCompiled: Bool { kernel != nil }

    /// 最近一次 apply 的结果：未调用 / 等待就绪… / 已挂载 /
    /// 开关已关闭 / HDR 源已跳过 / 纯音频已跳过 / 内核未加载：…。
    static var lastApplyStatus: String { statusLock.withLock { _lastApplyStatus } }

    /// 上次创建是否失败或还没挂上（可重试）。开关关闭 / 已挂载不算。
    /// 引擎在 item ready 后用它决定是否重试。
    static var lastApplyFailed: Bool {
        statusLock.withLock {
            _lastApplyStatus.hasPrefix("合成创建失败")
                || _lastApplyStatus.hasPrefix("内核未加载")
                || _lastApplyStatus.hasPrefix("无视频轨")
                || _lastApplyStatus.hasPrefix("加载轨道失败")
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

    private static func setLastApplyStatus(_ status: String) {
        statusLock.withLock { _lastApplyStatus = status }
    }

    private static var _kernelLoadError: String?

    /// 最近一次内核加载失败的原因（Metal 编译错误信息），成功时为 nil。
    static var kernelLoadError: String? { statusLock.withLock { _kernelLoadError } }

    /// nonisolated：内核的 nonisolated 初始化闭包里调用它；只写锁保护的变量。
    nonisolated private static func setKernelLoadError(_ message: String) {
        statusLock.withLock { _kernelLoadError = message }
    }

    /// 给新装载的视频项应用或清除滤镜。
    ///
    /// 只处理 SDR 源：脚本同样跳过 PQ/HLG 的 HDR 源（`source_hdr` 状态）。
    /// 音频-only 的项没有视频轨，不处理。开关关闭时清除已挂的合成。
    ///
    /// 注意：这里不用基于素材的合成工厂（`AVMutableVideoComposition(asset:…)` /
    /// 异步工厂），因为 HLS 桥接素材在 `.tracks` 里报 0 条轨道——播放列表已解析、
    /// 时长正常、视频照播，但轨道就是拿不到，工厂每次都返回 nil。改用手动建合成 +
    /// 自定义合成器（`HDRVisionVideoCompositor`），不依赖素材轨道。
    /// 手动建合成需要渲染尺寸，只能从已就绪视频项的 `presentationSize` 拿；
    /// 还没就绪时先记“等待就绪…”，ready 回调会再试一次。
    static func apply(to item: AVPlayerItem, source: PlayerStreamSource) {
        let settings = HDRVisionSettingsBox.shared.settings
        guard settings.enabled else {
            item.videoComposition = nil
            setLastApplyStatus("开关已关闭")
            return
        }
        guard !source.dynamicRange.isHDR else {
            item.videoComposition = nil
            setLastApplyStatus("HDR 源已跳过")
            return
        }
        guard source.playbackContentMode != .audioOnly else {
            item.videoComposition = nil
            setLastApplyStatus("纯音频已跳过")
            return
        }
        guard kernel != nil else {
            item.videoComposition = nil
            setLastApplyStatus("内核未加载：\(kernelLoadError ?? "无错误信息")")
            return
        }
        let presentationSize = item.presentationSize
        guard presentationSize.width > 0, presentationSize.height > 0 else {
            setLastApplyStatus("等待就绪…")
            return
        }
        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = HDRVisionVideoCompositor.self
        composition.renderSize = presentationSize
        composition.renderScale = Float(settings.renderScale)
        // 帧间隔给 1/60s（允许到 60fps；源是 30fps 时仍按源帧率出帧）。
        composition.frameDuration = CMTime(seconds: 1.0 / 60.0, preferredTimescale: 600)
        let duration = item.duration
        let timeRange: CMTimeRange
        if duration.isValid, duration.seconds > 0 {
            timeRange = CMTimeRange(start: .zero, duration: duration)
        } else {
            timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: 3600, preferredTimescale: 600))
        }
        // iOS 26 上 AVMutableVideoCompositionInstruction 的 requiredSourceTrackIDs
        // 是只读的（该类已废弃），不能直接赋值。改用新 Configuration API 建指令：
        // 每条候选视频轨一个层指令（层指令配置直接拿轨道 ID，不用素材轨道），
        // 指令要用的轨道就从层指令里带出来；HLS 视频轨通常从 1 开始编，
        // 哪个在播，合成器就收到哪个的帧。
        let layerInstructions = [1, 2, 3, 4, 5, 6, 7, 8].map { id in
            let layerConfig = AVVideoCompositionLayerInstruction.Configuration(trackID: CMPersistentTrackID(id))
            return AVVideoCompositionLayerInstruction(configuration: layerConfig)
        }
        var instructionConfig = AVVideoCompositionInstruction.Configuration(timeRange: timeRange)
        instructionConfig.layerInstructions = layerInstructions
        let instruction = AVVideoCompositionInstruction(configuration: instructionConfig)
        composition.instructions = [instruction]
        item.videoComposition = composition
        setLastApplyStatus("已挂载")
    }

    // MARK: - 逐帧应用

    /// 不加 private：自定义合成器（HDRVisionVideoCompositor）逐帧调用它。
    /// nonisolated：合成器跑在渲染队列上；只做纯计算 + CIKernel.apply。
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
