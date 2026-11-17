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
    // MARK: - 内核（Metal 源码，运行时编译一次；失败则整个功能静默关闭）

    /// 运行时编译 Metal 内核（iOS 15+ 的 stitchable 方式）。
    ///
    /// 注意：`CIColorKernel(source:)` 只接受旧的 CIKL 语言（GLSL 方言），
    /// 传 Metal 源码会直接返回 nil；Metal 源码必须以 `[[stitchable]]`
    /// 形式走 `CIKernel.kernels(withMetalString:)` 编译。
    private static let kernel: CIColorKernel? = {
        do {
            let kernels = try CIKernel.kernels(withMetalString: kernelSource)
            if let colorKernel = kernels.compactMap({ $0 as? CIColorKernel }).first {
                return colorKernel
            }
            setKernelLoadError("编译成功但未找到 CIColorKernel")
            PlayerMetricsLog.logger.error("hdrVisionKernel load failed: no CIColorKernel in compiled kernels")
        } catch {
            setKernelLoadError(error.localizedDescription)
            PlayerMetricsLog.logger.error("hdrVisionKernel compile failed: \(error.localizedDescription)")
        }
        return nil
    }()

    // MARK: - 诊断状态（设置页读取）

    private static let statusLock = NSLock()
    private static var _lastApplyStatus = "未调用"
    private static var _framesProcessed = 0
    private static var _framesPassedThrough = 0

    /// Metal 内核是否编译成功。首次读取会触发编译。
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

// MARK: - Metal 内核源码（WGSL → MSL 逐句移植）
//
// 入口函数按运行时编译的 stitchable 内核约定：`[[stitchable]]`，首参
// `coreimage::sampler_h`（当前像素用 `s.sample(s.coord())` 取，邻域用
// `s.sample(dc + offset)` 取，不需要 `destination` 参数）；其余 19 个
// float 参数与 `computeUniforms` 的顺序一致。
// 注意：`CIColorKernel(source:)` 只接受旧的 CIKL 语言，Metal 源码必须
// 走 `CIKernel.kernels(withMetalString:)` 编译（见下方 kernel 加载）。

private let kernelSource = #"""
#include <CoreImage/CoreImage.h>
using namespace metal;
using namespace coreimage;

float luminance_hdv(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

float3 processInOKLab_hdv(float3 color, float saturationFactor) {
    float3 c = max(color, float3(0.0));
    float l = 0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b;
    float m = 0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b;
    float s = 0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b;
    float l_ = pow(max(l, 1e-8), 1.0 / 3.0);
    float m_ = pow(max(m, 1e-8), 1.0 / 3.0);
    float s_ = pow(max(s, 1e-8), 1.0 / 3.0);
    float L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_;
    float a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_;
    float b = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_;
    a *= saturationFactor;
    b *= saturationFactor;
    float l2_ = L + 0.3963377774 * a + 0.2158037573 * b;
    float m2_ = L - 0.1055613458 * a - 0.0638541728 * b;
    float s2_ = L - 0.0894841775 * a - 1.2914855480 * b;
    float l2 = l2_ * l2_ * l2_;
    float m2 = m2_ * m2_ * m2_;
    float s2 = s2_ * s2_ * s2_;
    return float3(
        4.0767416621 * l2 - 3.3077115913 * m2 + 0.2309699292 * s2,
        -1.2684380046 * l2 + 2.6097574011 * m2 - 0.3413193965 * s2,
        -0.0041960863 * l2 - 0.7034186147 * m2 + 1.7076147010 * s2
    );
}

float3 boostHighlights_hdv(float3 color, float threshold, float maxBoost) {
    float luma = luminance_hdv(color);
    float p = 2.0 / max(1.0 - threshold, 0.05);
    float lumaClamped = clamp(luma, 0.0, 1.0);
    float s = pow(lumaClamped, p);
    float gain = 1.0 + (maxBoost - 1.0) * s;
    return color * gain;
}

float3 crushShadows_hdv(float3 color, float threshold, float strength) {
    float luma = luminance_hdv(color);
    if (luma >= threshold) {
        return color;
    }
    if (luma < 1e-5) {
        return color;
    }
    float x = clamp(luma / threshold, 0.0, 1.0);
    float exponent = 1.0 + strength * 2.0;
    float y = pow(x, exponent);
    float newLuma = threshold * y;
    float scale = newLuma / luma;
    return color * scale;
}

float3 toneMapBrightness_hdv(float3 color, float peak) {
    float luma = luminance_hdv(color);
    if (luma <= 1.0) {
        return color;
    }
    float excess = luma - 1.0;
    float compressed = 1.0 + excess * (peak - 1.0) / (excess + peak - 1.0);
    return color * (compressed / luma);
}

float3 bt2446aInverseWithLift_hdv(
    float3 color,
    float peakBrightness,
    float boost,
    float pHDR,
    float logPHDR,
    float midToneLift
) {
    float luma = luminance_hdv(color);
    float lumaClamped = clamp(luma, 0.0, 1.0);
    if (lumaClamped < 1e-5) {
        return color;
    }

    float Yp;
    if (lumaClamped <= 0.7969) {
        Yp = lumaClamped / 1.0770;
    } else if (lumaClamped >= 0.99545) {
        Yp = 2.0 * lumaClamped - 1.0;
    } else {
        float a = 1.1510;
        float b = -2.7811;
        float c = 0.6302 + lumaClamped;
        float disc = b * b - 4.0 * a * c;
        float sqrtDisc = sqrt(max(disc, 0.0));
        Yp = (-b - sqrtDisc) / (2.0 * a);
    }

    float Y = (exp(Yp * logPHDR) - 1.0) / (pHDR - 1.0);
    float outputLuma = Y * peakBrightness * boost;
    float gain = outputLuma / lumaClamped;
    float3 result = color * gain;

    float maxOut = 5.0;
    if (outputLuma > maxOut) {
        float excess = outputLuma - maxOut;
        float compressed = maxOut + excess / (1.0 + excess / maxOut);
        result = result * (compressed / outputLuma);
        outputLuma = compressed;
    }

    if (midToneLift > 0.001 && outputLuma > 1e-5) {
        float effectivePeak = min(peakBrightness * boost, 5.0);
        float norm = clamp(outputLuma / effectivePeak, 0.0, 1.0);
        float gamma = 1.0 / (1.0 + midToneLift * 0.7);
        float liftedNorm = pow(norm, gamma);
        float newLuma = liftedNorm * effectivePeak;
        float lumaScale = max(newLuma / outputLuma, 1.0);
        result = result * lumaScale;
    }

    return result;
}

struct HDRVisionUniforms {
    float exposureMultiplier;
    float saturation;
    float skipSaturation;
    float peakBrightness;
    float useBT2446a;
    float btBoost;
    float pHDR;
    float logPHDR;
    float midToneLift;
    float brightnessThreshold;
    float maxBoost;
    float shadowThreshold;
    float shadowCrush;
    float skipBoost;
    float skipShadow;
};

float3 applyColorPipeline_hdv(float3 color, HDRVisionUniforms u) {
    float3 c = color * u.exposureMultiplier;
    if (u.useBT2446a > 0.5) {
        c = bt2446aInverseWithLift_hdv(
            c,
            u.peakBrightness,
            u.btBoost,
            u.pHDR,
            u.logPHDR,
            u.midToneLift
        );
    } else {
        if (u.skipShadow < 0.5) {
            c = crushShadows_hdv(c, u.shadowThreshold, u.shadowCrush);
        }
        if (u.skipBoost < 0.5) {
            c = boostHighlights_hdv(c, u.brightnessThreshold, u.maxBoost);
        }
        c = toneMapBrightness_hdv(c, u.peakBrightness);
    }
    if (u.skipSaturation < 0.5) {
        c = processInOKLab_hdv(c, u.saturation);
    }
    return c;
}

struct RingResult_hdv {
    float3 avg;
    float variance;
};

RingResult_hdv sampleRing_hdv(coreimage::sampler_h s, float2 dc, float radius) {
    float2 t = float2(radius, radius);
    float3 s0 = s.sample(dc + float2(t.x, 0.0)).rgb;
    float3 s1 = s.sample(dc - float2(t.x, 0.0)).rgb;
    float3 s2 = s.sample(dc + float2(0.0, t.y)).rgb;
    float3 s3 = s.sample(dc - float2(0.0, t.y)).rgb;
    float3 s4 = s.sample(dc + t).rgb;
    float3 s5 = s.sample(dc - t).rgb;
    float3 s6 = s.sample(dc + float2(t.x, -t.y)).rgb;
    float3 s7 = s.sample(dc + float2(-t.x, t.y)).rgb;

    float3 avg = (s0 + s1 + s2 + s3 + s4 + s5 + s6 + s7) * 0.125;

    float d0 = abs(s0.r - avg.r) + abs(s0.g - avg.g) + abs(s0.b - avg.b);
    float d1 = abs(s1.r - avg.r) + abs(s1.g - avg.g) + abs(s1.b - avg.b);
    float d2 = abs(s2.r - avg.r) + abs(s2.g - avg.g) + abs(s2.b - avg.b);
    float d3 = abs(s3.r - avg.r) + abs(s3.g - avg.g) + abs(s3.b - avg.b);
    float d4 = abs(s4.r - avg.r) + abs(s4.g - avg.g) + abs(s4.b - avg.b);
    float d5 = abs(s5.r - avg.r) + abs(s5.g - avg.g) + abs(s5.b - avg.b);
    float d6 = abs(s6.r - avg.r) + abs(s6.g - avg.g) + abs(s6.b - avg.b);
    float d7 = abs(s7.r - avg.r) + abs(s7.g - avg.g) + abs(s7.b - avg.b);
    float variance = (d0 + d1 + d2 + d3 + d4 + d5 + d6 + d7) * 0.125;

    RingResult_hdv r;
    r.avg = avg;
    r.variance = variance;
    return r;
}

float3 applyDeband_hdv(coreimage::sampler_h s, float2 dc, float3 centerColor, float threshold) {
    RingResult_hdv r3 = sampleRing_hdv(s, dc, 3.0);
    RingResult_hdv r8 = sampleRing_hdv(s, dc, 8.0);
    RingResult_hdv r12 = sampleRing_hdv(s, dc, 12.0);
    RingResult_hdv r28 = sampleRing_hdv(s, dc, 28.0);

    float d3 = smoothstep(threshold * 0.5, threshold * 3.0, r3.variance);
    float d8 = smoothstep(threshold * 0.5, threshold * 3.0, r8.variance);
    float d12 = smoothstep(threshold * 0.5, threshold * 3.0, r12.variance);
    float detailMask = max(max(d3, d8), d12);

    float flatLarge = 1.0 - smoothstep(threshold * 0.5, threshold * 2.5, r28.variance);

    float strength = flatLarge * (1.0 - detailMask) * 0.92;

    float3 smoothValue = r3.avg * 0.2 + r12.avg * 0.5 + r28.avg * 0.3;

    return mix(centerColor, smoothValue, strength);
}

float3 applyCAS_hdv(coreimage::sampler_h s, float2 dc, float3 centerRGB, float strength) {
    if (strength < 0.01) {
        return centerRGB;
    }

    float3 cN = s.sample(dc + float2(0.0, -1.0)).rgb;
    float3 cS = s.sample(dc + float2(0.0, 1.0)).rgb;
    float3 cE = s.sample(dc + float2(1.0, 0.0)).rgb;
    float3 cW = s.sample(dc + float2(-1.0, 0.0)).rgb;
    float3 cNE = s.sample(dc + float2(1.0, -1.0)).rgb;
    float3 cNW = s.sample(dc + float2(-1.0, -1.0)).rgb;
    float3 cSE = s.sample(dc + float2(1.0, 1.0)).rgb;
    float3 cSW = s.sample(dc + float2(-1.0, 1.0)).rgb;

    float2 t16 = float2(16.0, 16.0);
    float3 fN16 = s.sample(dc + float2(0.0, -t16.y)).rgb;
    float3 fS16 = s.sample(dc + float2(0.0, t16.y)).rgb;
    float3 fE16 = s.sample(dc + float2(t16.x, 0.0)).rgb;
    float3 fW16 = s.sample(dc + float2(-t16.x, 0.0)).rgb;

    float2 t32 = float2(32.0, 32.0);
    float3 fN32 = s.sample(dc + float2(0.0, -t32.y)).rgb;
    float3 fS32 = s.sample(dc + float2(0.0, t32.y)).rgb;
    float3 fE32 = s.sample(dc + float2(t32.x, 0.0)).rgb;
    float3 fW32 = s.sample(dc + float2(-t32.x, 0.0)).rgb;

    float3 lumaW = float3(0.2126, 0.7152, 0.0722);
    float centerLuma = dot(centerRGB, lumaW);

    float lumaN = dot(cN, lumaW);
    float lumaS = dot(cS, lumaW);
    float lumaE = dot(cE, lumaW);
    float lumaWv = dot(cW, lumaW);
    float lumaNW = dot(cNW, lumaW);
    float lumaNE = dot(cNE, lumaW);
    float lumaSW = dot(cSW, lumaW);
    float lumaSE = dot(cSE, lumaW);

    float lumaMin = min(min(min(lumaN, lumaS), min(lumaE, lumaWv)),
                        min(min(lumaNW, lumaNE), min(lumaSW, lumaSE)));
    float lumaMax = max(max(max(lumaN, lumaS), max(lumaE, lumaWv)),
                        max(max(lumaNW, lumaNE), max(lumaSW, lumaSE)));

    float range = max(lumaMax - lumaMin, 1e-5);
    float softMin = max(0.0, lumaMin - range * 0.25);
    float softMax = min(2.0, lumaMax + range * 0.25);

    float3 avg = (cN + cS + cE + cW) * 0.125 + (cNE + cNW + cSE + cSW) * 0.0625;
    float avgLuma = dot(avg, lumaW);

    float varN = abs(lumaN - avgLuma);
    float varS = abs(lumaS - avgLuma);
    float varE = abs(lumaE - avgLuma);
    float varW = abs(lumaWv - avgLuma);
    float localVar = (varN + varS + varE + varW) * 0.25;

    float f16Avg = (dot(fN16, lumaW) + dot(fS16, lumaW) + dot(fE16, lumaW) + dot(fW16, lumaW)) * 0.25;
    float f32Avg = (dot(fN32, lumaW) + dot(fS32, lumaW) + dot(fE32, lumaW) + dot(fW32, lumaW)) * 0.25;
    float farContrast16 = abs(centerLuma - f16Avg);
    float farContrast32 = abs(centerLuma - f32Avg);
    float farContrast = min(farContrast16, farContrast32);

    float noiseMask = smoothstep(0.005, 0.03, localVar);
    float trueEdgeMask = smoothstep(0.02, 0.05, farContrast);

    float effectiveStrength = strength * noiseMask * trueEdgeMask;

    float3 detail = centerRGB - avg;
    float3 sharpened = centerRGB + detail * effectiveStrength;

    float outLuma = dot(sharpened, lumaW);
    float clampedLuma = clamp(outLuma, softMin, softMax);
    float lumaScale = clampedLuma / max(outLuma, 1e-6);

    return sharpened * lumaScale;
}

[[stitchable]] float4 hdrVisionKernel(
    coreimage::sampler_h s,
    float exposureMultiplier,
    float saturation,
    float skipSaturation,
    float peakBrightness,
    float useBT2446a,
    float btBoost,
    float pHDR,
    float logPHDR,
    float midToneLift,
    float brightnessThreshold,
    float maxBoost,
    float shadowThreshold,
    float shadowCrush,
    float skipBoost,
    float skipShadow,
    float debandEnabled,
    float debandThreshold,
    float sharpenEnabled,
    float sharpenStrength
) {
    float2 dc = s.coord();
    float3 color = s.sample(dc).rgb;

    if (debandEnabled > 0.5) {
        color = applyDeband_hdv(s, dc, color, debandThreshold);
    }

    if (sharpenEnabled > 0.5) {
        color = applyCAS_hdv(s, dc, color, sharpenStrength);
    }

    HDRVisionUniforms u;
    u.exposureMultiplier = exposureMultiplier;
    u.saturation = saturation;
    u.skipSaturation = skipSaturation;
    u.peakBrightness = peakBrightness;
    u.useBT2446a = useBT2446a;
    u.btBoost = btBoost;
    u.pHDR = pHDR;
    u.logPHDR = logPHDR;
    u.midToneLift = midToneLift;
    u.brightnessThreshold = brightnessThreshold;
    u.maxBoost = maxBoost;
    u.shadowThreshold = shadowThreshold;
    u.shadowCrush = shadowCrush;
    u.skipBoost = skipBoost;
    u.skipShadow = skipShadow;
    color = applyColorPipeline_hdv(color, u);

    return float4(color, 1.0);
}
"""#
