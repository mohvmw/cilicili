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
// 管线顺序与脚本一致：deband（4 环邻域采样）→ CAS（8 邻域 + 16/32px
// 远采样）→ 曝光 → BT.2446a / power → OKLab 饱和度。邻域采样用归一化
// UV，像素偏移乘 texelSize（= 1 / 源尺寸）换算；sampler 为 clamp_to_edge，
// 边缘不采黑。deband/CAS 的开关与强度由设置里的 debandEnabled /
// debandThreshold / sharpenEnabled / sharpenStrength 控制（默认开）。

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

// ---- 去色带（deband）与 CAS 锐化：从 CI 内核移植到计算核 ----
// CI 版用 sampler_h 在像素坐标上采样邻域；计算核用归一化 UV 采样，
// 像素偏移要乘 texelSize（= 1 / 源尺寸）换算成 UV 偏移。
// 顺序与脚本一致：deband → CAS → 色彩管线。

struct RingResult_c {
    float3 avg;
    float variance;
};

RingResult_c sampleRing_c(
    texture2d<float, access::sample> tex,
    sampler s,
    float2 uv,
    float2 texelSize,
    float radius
) {
    float2 t = float2(radius, radius) * texelSize;
    float3 s0 = tex.sample(s, uv + float2(t.x, 0.0)).rgb;
    float3 s1 = tex.sample(s, uv - float2(t.x, 0.0)).rgb;
    float3 s2 = tex.sample(s, uv + float2(0.0, t.y)).rgb;
    float3 s3 = tex.sample(s, uv - float2(0.0, t.y)).rgb;
    float3 s4 = tex.sample(s, uv + t).rgb;
    float3 s5 = tex.sample(s, uv - t).rgb;
    float3 s6 = tex.sample(s, uv + float2(t.x, -t.y)).rgb;
    float3 s7 = tex.sample(s, uv + float2(-t.x, t.y)).rgb;

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

    RingResult_c r;
    r.avg = avg;
    r.variance = variance;
    return r;
}

float3 applyDeband_c(
    texture2d<float, access::sample> tex,
    sampler s,
    float2 uv,
    float2 texelSize,
    float3 centerColor,
    float threshold
) {
    RingResult_c r3 = sampleRing_c(tex, s, uv, texelSize, 3.0);
    RingResult_c r8 = sampleRing_c(tex, s, uv, texelSize, 8.0);
    RingResult_c r12 = sampleRing_c(tex, s, uv, texelSize, 12.0);
    RingResult_c r28 = sampleRing_c(tex, s, uv, texelSize, 28.0);

    float d3 = smoothstep(threshold * 0.5, threshold * 3.0, r3.variance);
    float d8 = smoothstep(threshold * 0.5, threshold * 3.0, r8.variance);
    float d12 = smoothstep(threshold * 0.5, threshold * 3.0, r12.variance);
    float detailMask = max(max(d3, d8), d12);

    float flatLarge = 1.0 - smoothstep(threshold * 0.5, threshold * 2.5, r28.variance);

    float strength = flatLarge * (1.0 - detailMask) * 0.92;

    float3 smoothValue = r3.avg * 0.2 + r12.avg * 0.5 + r28.avg * 0.3;

    return mix(centerColor, smoothValue, strength);
}

float3 applyCAS_c(
    texture2d<float, access::sample> tex,
    sampler s,
    float2 uv,
    float2 texelSize,
    float3 centerRGB,
    float strength
) {
    if (strength < 0.01) {
        return centerRGB;
    }

    float2 o1 = float2(1.0, 1.0) * texelSize;
    float3 cN = tex.sample(s, uv + float2(0.0, -o1.y)).rgb;
    float3 cS = tex.sample(s, uv + float2(0.0, o1.y)).rgb;
    float3 cE = tex.sample(s, uv + float2(o1.x, 0.0)).rgb;
    float3 cW = tex.sample(s, uv - float2(o1.x, 0.0)).rgb;
    float3 cNE = tex.sample(s, uv + float2(o1.x, -o1.y)).rgb;
    float3 cNW = tex.sample(s, uv + float2(-o1.x, -o1.y)).rgb;
    float3 cSE = tex.sample(s, uv + float2(o1.x, o1.y)).rgb;
    float3 cSW = tex.sample(s, uv + float2(-o1.x, o1.y)).rgb;

    float2 t16 = float2(16.0, 16.0) * texelSize;
    float3 fN16 = tex.sample(s, uv + float2(0.0, -t16.y)).rgb;
    float3 fS16 = tex.sample(s, uv + float2(0.0, t16.y)).rgb;
    float3 fE16 = tex.sample(s, uv + float2(t16.x, 0.0)).rgb;
    float3 fW16 = tex.sample(s, uv - float2(t16.x, 0.0)).rgb;

    float2 t32 = float2(32.0, 32.0) * texelSize;
    float3 fN32 = tex.sample(s, uv + float2(0.0, -t32.y)).rgb;
    float3 fS32 = tex.sample(s, uv + float2(0.0, t32.y)).rgb;
    float3 fE32 = tex.sample(s, uv + float2(t32.x, 0.0)).rgb;
    float3 fW32 = tex.sample(s, uv - float2(t32.x, 0.0)).rgb;

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
    // 去色带 → CAS，与脚本顺序一致；开关由设置里的 debandEnabled /
    // sharpenEnabled 控制，默认开（与脚本默认值一致）。
    float2 texelSize = 1.0 / p.srcSize;
    if (u.debandEnabled > 0.5) {
        color = applyDeband_c(srcTexture, s, srcUV, texelSize, color, u.debandThreshold);
    }
    if (u.sharpenEnabled > 0.5) {
        color = applyCAS_c(srcTexture, s, srcUV, texelSize, color, u.sharpenStrength);
    }
    // 色彩管线（BT.2446a / power + OKLab 饱和度）。输出可超 1.0，
    // 写进 rgba16Float 纹理保留给 EDR 显示，不截断。
    color = applyColorPipeline_c(color, u);
    dstTexture.write(float4(color, 1.0), gid);
}
