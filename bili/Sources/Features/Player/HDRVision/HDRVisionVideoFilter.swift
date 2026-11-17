import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import os

/// HDR 视界视频滤镜。
///
/// 把脚本的 WGSL 管线（去色带 → CAS 锐化 → 曝光 → BT.2446a/幂函数映射 → OKLab 饱和度）
/// 逐句移植为 Core Image Metal 内核，经 `AVVideoComposition` 挂到 `AVPlayerItem` 上。
/// 这是 iOS 上与 mpv `glsl-shaders` 对应的做法：AVPlayer 没有 shader 挂载点，
/// 视频合成是唯一能在不替换整个播放面的前提下逐帧处理画面的官方路径。
///
/// 注意（与 PiliPlus 的 GLSL 移植一样）：
/// - 内核按显示参考值运算，与脚本的纹理值含义一致；SDR 源（BT.709）上效果与脚本一致。
/// - 输出可能超过 1.0（BT.2446a 上限 5.0），能否在 XDR 屏上呈现为真 HDR 亮度，
///   取决于播放层是否保留扩展范围，需真机验证；至少在 SDR 内是同款增强。
enum HDRVisionVideoFilter {
    // MARK: - 内核（构建期编译的 stitchable 内核，从 default.metallib 加载）

    /// 从构建期编译好的 `default.metallib` 加载 stitchable 内核。
    ///
    /// 内核源码在同目录的 `HDRVisionKernel.metal`（`[[stitchable]]`，首参
    /// `sample_t`、末参 `destination` 的颜色内核形式），Xcode 在构建时把它
    /// 编进 `default.metallib`；工程需在 Metal 链接参数里加
    /// `-framework CoreImage`（见 project.pbxproj 的 MTLLINKER_FLAGS），
    /// 否则链接器找不到 Core Image 的 Metal 符号。
    /// 运行时编译（`kernels(withMetalString:)`）在真机上以 CIKernel error 13
    /// 失败且无详细信息，改走构建期编译后，Metal 源码错误会直接出现在构建日志里。
    private static let kernel: CIColorKernel? = {
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
        guard let kernel = CIColorKernel(functionName: "hdrVisionKernel", fromMetalLibraryData: data) else {
            setKernelLoadError("default.metallib 中未找到 hdrVisionKernel（或不是颜色内核）")
            PlayerMetricsLog.logger.error("hdrVisionKernel load failed: function not found in default.metallib")
            return nil
        }
        return kernel
    }()

    // MARK: - 诊断状态（设置页读取）

    private static let statusLock = NSLock()
    private static var _lastApplyStatus = "未调用"
    private static var _framesProcessed = 0
    private static var _framesPassedThrough = 0

    /// Metal 内核是否加载成功（从 default.metallib）。首次读取会触发加载。
    static var kernelCompiled: Bool { kernel != nil }

    /// 最近一次 apply 的结果：未调用 / 已挂载 / 开关已关闭 / HDR 源已跳过 / 纯音频已跳过 / 内核编译失败。
    static var lastApplyStatus: String { statusLock.withLock { _lastApplyStatus } }

    /// 逐帧回调里内核成功处理 / 原样直通的帧数。直通一直涨而处理帧为 0，说明每帧都没进内核。
    static var frameCounts: (processed: Int, passedThrough: Int) {
        statusLock.withLock { (_framesProcessed, _framesPassedThrough) }
    }

    private static func setLastApplyStatus(_ status: String) {
        statusLock.withLock { _lastApplyStatus = status }
    }

    private static var _kernelLoadError: String?

    /// 最近一次内核加载失败的原因（Metal 编译错误信息），成功时为 nil。
    static var kernelLoadError: String? { statusLock.withLock { _kernelLoadError } }

    private static func setKernelLoadError(_ message: String) {
        statusLock.withLock { _kernelLoadError = message }
    }

    /// 给新装载的视频项应用或清除滤镜。
    ///
    /// 只处理 SDR 源：脚本同样跳过 PQ/HLG 的 HDR 源（`source_hdr` 状态）。
    /// 音频-only 的项没有视频轨，不处理。开关关闭时清除已挂的合成。
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
        guard let composition = makeVideoComposition(for: item.asset, settings: settings) else {
            item.videoComposition = nil
            setLastApplyStatus("内核编译失败")
            return
        }
        item.videoComposition = composition
        setLastApplyStatus("已挂载")
    }

    /// 为一个素材建视频合成。renderScale 来自设置；帧间隔按素材帧率取。
    static func makeVideoComposition(for asset: AVAsset, settings: HDRVisionSettings) -> AVMutableVideoComposition? {
        guard let kernel else { return nil }
        let composition = AVMutableVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
            let settings = HDRVisionSettingsBox.shared.settings
            guard let output = applyKernel(kernel, to: request.sourceImage, settings: settings) else {
                statusLock.withLock { _framesPassedThrough += 1 }
                request.finish(with: request.sourceImage, context: nil)
                return
            }
            statusLock.withLock { _framesProcessed += 1 }
            request.finish(with: output, context: nil)
        })
        composition.renderScale = Float(settings.renderScale)
        if let track = asset.tracks(withMediaType: .video).first,
           track.nominalFrameRate > 0 {
            composition.frameDuration = CMTime(
                seconds: 1.0 / Double(track.nominalFrameRate),
                preferredTimescale: 600
            )
        }
        return composition
    }

    // MARK: - 逐帧应用

    private static func applyKernel(
        _ kernel: CIColorKernel,
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
    private static func computeUniforms(_ settings: HDRVisionSettings) -> [Float] {
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
