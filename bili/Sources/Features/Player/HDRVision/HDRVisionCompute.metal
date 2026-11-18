#include <metal_stdlib>

using namespace metal;

// HDR 视界 Metal 计算核（替代 Core Image 内核的显示路径）。
//
// 为什么不用 Core Image：CI 内核 + CIContext 渲染在显示上有三个解不掉的问题——
// ① 浮点纹理 + EDR 时色彩空间对不上，画面泛白；② CIContext.render 的 bounds
// 缩放不可靠，画面总被放大；③ CIContext 可能把超 1.0 的值截掉，亮度不变。
// 计算核直接读写纹理，色彩（BGRA→RGB 归一化）、几何（目标矩形映射）、
// 亮度（float 输出，超 1.0 保留给 EDR）全部自己控制。
//
// 输入是引擎 videoOutput 给的 32BGRA 像素缓冲（已是 RGB，不用 YUV 解码），
// 经 CVMetalTextureCache 转成 bgra8Unorm 纹理；输出直接写 drawable 的
// rgba16Float 纹理（EDR），超 1.0 的高光在 XDR 屏上真正亮起来。
//
// 注意：去色带（deband）与 CAS 锐化暂未移植到计算核（它们要采邻域，
// 在计算核里要另外处理）；先保证核心的 BT.2446a / power 色彩管线、
// 正确的几何与色彩、可见的亮度变化。去色带/CAS 后续再补。

float luminance_c(float3 c) {
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

float3 processInOKLab_c(float3 color, float saturationFactor) {
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

float3 boostHighlights_c(float3 color, float threshold, float maxBoost) {
    float luma = luminance_c(color);
    float p = 2.0 / max(1.0 - threshold, 0.05);
    float lumaClamped = clamp(luma, 0.0, 1.0);
    float s = pow(lumaClamped, p);
    float gain = 1.0 + (maxBoost - 1.0) * s;
    return color * gain;
}

float3 crushShadows_c(float3 color, float threshold, float strength) {
    float luma = luminance_c(color);
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

float3 toneMapBrightness_c(float3 color, float peak) {
    float luma = luminance_c(color);
    if (luma <= 1.0) {
        return color;
    }
    float excess = luma - 1.0;
    float compressed = 1.0 + excess * (peak - 1.0) / (excess + peak - 1.0);
    return color * (compressed / luma);
}

float3 bt2446aInverseWithLift_c(
    float3 color,
    float peakBrightness,
    float boost,
    float pHDR,
    float logPHDR,
    float midToneLift
) {
    float luma = luminance_c(color);
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

// 与 HDRVisionVideoFilter.computeUniforms 顺序一致的 19 个 float。
// Swift 侧直接传 [Float]（19 个）作 buffer，布局就是连续 19 个 float。
struct HDRVisionComputeUniforms {
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
    float debandEnabled;
    float debandThreshold;
    float sharpenEnabled;
    float sharpenStrength;
};

float3 applyColorPipeline_c(float3 color, HDRVisionComputeUniforms u) {
    float3 c = color * u.exposureMultiplier;
    if (u.useBT2446a > 0.5) {
        c = bt2446aInverseWithLift_c(
            c,
            u.peakBrightness,
            u.btBoost,
            u.pHDR,
            u.logPHDR,
            u.midToneLift
        );
    } else {
        if (u.skipShadow < 0.5) {
            c = crushShadows_c(c, u.shadowThreshold, u.shadowCrush);
        }
        if (u.skipBoost < 0.5) {
            c = boostHighlights_c(c, u.brightnessThreshold, u.maxBoost);
        }
        c = toneMapBrightness_c(c, u.peakBrightness);
    }
    if (u.skipSaturation < 0.5) {
        c = processInOKLab_c(c, u.saturation);
    }
    return c;
}

struct HDRVisionComputeParams {
    float2 destOrigin;  // 目标矩形左上角（目标纹理像素坐标）
    float2 destSize;    // 目标矩形尺寸（目标纹理像素）
    float2 srcSize;     // 源纹理尺寸（像素）
    float2 dstSize;     // 目标纹理尺寸（像素）
};

kernel void hdrVisionCompute(
    texture2d<float, access::sample> srcTexture [[texture(0)]],
    texture2d<float, access::write> dstTexture [[texture(1)]],
    constant HDRVisionComputeUniforms &u [[buffer(0)]],
    constant HDRVisionComputeParams &p [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    // 超出目标纹理不写。
    if (gid.x >= uint(p.dstSize.x) || gid.y >= uint(p.dstSize.y)) {
        return;
    }
    float2 pos = float2(gid);
    // 目标矩形之外（黑边）写黑。
    if (pos.x < p.destOrigin.x || pos.y < p.destOrigin.y ||
        pos.x >= p.destOrigin.x + p.destSize.x || pos.y >= p.destOrigin.y + p.destSize.y) {
        dstTexture.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        return;
    }
    // 目标像素 → 源归一化坐标（取像素中心，线性过滤平滑缩放）。
    float2 srcUV = float2(
        (pos.x - p.destOrigin.x + 0.5) / p.destSize.x,
        (pos.y - p.destOrigin.y + 0.5) / p.destSize.y
    );
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float3 color = srcTexture.sample(s, srcUV).rgb;
    // 色彩管线（BT.2446a / power + OKLab 饱和度）。输出可超 1.0，
    // 写进 rgba16Float 纹理保留给 EDR 显示，不截断。
    color = applyColorPipeline_c(color, u);
    dstTexture.write(float4(color, 1.0), gid);
}
