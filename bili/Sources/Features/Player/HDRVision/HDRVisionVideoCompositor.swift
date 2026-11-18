import AVFoundation
import CoreImage
import CoreMedia
import Foundation

/// 自定义视频合成器：把 HDR 视界内核逐帧应用到播放画面上。
///
/// 【已停用，保留作参考】视频合成路线已死：HLS 桥接素材在 `AVAsset.tracks`
/// 里报 0 条轨道，合成引擎建不出自定义合成器——旧的 `AVMutableVideoComposition`
/// 和新的 `AVVideoComposition.Configuration` 都试过，合成器一直“未建”
///（实测 2026-11-18）。现改走 `AVPlayerItemVideoOutput` 拉帧 + Metal 层显示
///（`HDRVisionVideoOutputDisplay`），不再挂 videoComposition，本文件不再被调用。
///
/// 轨道 ID 是按经验列的：HLS 主播放列表有多个清晰度分片，AVFoundation
/// 给视频轨分配的 ID 通常从 1 开始；指令里列 1…8，哪个是当前在播的视频轨，
/// 合成器就收到哪个的帧（其余 ID 没有帧，不产生请求）。视频合成只收视频帧，
/// 音频轨即使在列表里也不会产生视频请求，所以多列几个无害。
/// 若已处理帧 / 直通帧一直 0/0，说明 ID 猜错了，需调整候选列表；
/// 关掉 HDR 开关即可恢复正常播放（开关清除 videoComposition）。
///
/// 注意（iOS 26 SDK）：`AVVideoCompositing` 的像素缓冲属性在新 SDK 里是
/// `[String: any Sendable]`（旧的 `[String: Any]` 不再满足协议），且必须提供
/// `sourcePixelBufferAttributes`（可选字典）；像素格式值必须是单个值
///（写成数组会导致合成器收不到请求），并加上 `kCVPixelBufferMetalCompatibilityKey`
///（否则 Metal 渲染可能黑屏）。
final class HDRVisionVideoCompositor: NSObject, AVVideoCompositing {

    /// 候选视频轨道 ID。
    private static let candidateTrackIDs: [CMPersistentTrackID] = [1, 2, 3, 4, 5, 6, 7, 8]

    private let ciContext = CIContext()

    private var renderContext: AVVideoCompositionRenderContext?

    // MARK: - AVVideoCompositing

    /// 合成器接受的源帧格式：32 位 BGRA，Metal 兼容。
    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            String(kCVPixelBufferPixelFormatTypeKey): Int(kCVPixelFormatType_32BGRA),
            String(kCVPixelBufferMetalCompatibilityKey): true,
        ]
    }

    /// 渲染上下文输出缓冲的格式：32 位 BGRA，Metal 兼容。
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [
            String(kCVPixelBufferPixelFormatTypeKey): Int(kCVPixelFormatType_32BGRA),
            String(kCVPixelBufferMetalCompatibilityKey): true,
        ]
    }

    /// 合成器支持的源帧格式（与上面一致）。
    var supportedPixelBufferAttributes: [String: any Sendable] {
        [
            String(kCVPixelBufferPixelFormatTypeKey): Int(kCVPixelFormatType_32BGRA),
            String(kCVPixelBufferMetalCompatibilityKey): true,
        ]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        renderContext = newRenderContext
        // 诊断用的“合成器已建”标志已随合成路线一起移除（见文件头）。
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let renderContext else {
            request.finish(with: NSError(domain: "HDRVisionVideoCompositor", code: -1, userInfo: [NSLocalizedDescriptionKey: "render context 未设置"]))
            return
        }
        // 找到当前在播的视频轨的帧：先试请求自带的轨道 ID（指令的层指令
        // 决定了这次请求覆盖哪些轨道），再试候选列表兜底。
        var sourcePixelBuffer: CVPixelBuffer?
        var trackIDs = request.sourceTrackIDs.map { CMPersistentTrackID($0.int32Value) }
        trackIDs.append(contentsOf: Self.candidateTrackIDs)
        for trackID in trackIDs {
            if let frame = request.sourceFrame(byTrackID: trackID) {
                sourcePixelBuffer = frame
                break
            }
        }
        guard let sourcePixelBuffer else {
            // 没有任何候选轨有帧（轨道 ID 全猜错，或当前没有视频帧）。
            HDRVisionVideoFilter.noteFramePassedThrough()
            request.finish(with: NSError(domain: "HDRVisionVideoCompositor", code: -2, userInfo: [NSLocalizedDescriptionKey: "无视频轨帧"]))
            return
        }
        guard let outputPixelBuffer = renderContext.newPixelBuffer() else {
            HDRVisionVideoFilter.noteFramePassedThrough()
            request.finish(with: NSError(domain: "HDRVisionVideoCompositor", code: -3, userInfo: [NSLocalizedDescriptionKey: "无法创建输出像素缓冲"]))
            return
        }
        let settings = HDRVisionSettingsBox.shared.settings
        let sourceImage = CIImage(cvPixelBuffer: sourcePixelBuffer)
        if let kernel = HDRVisionVideoFilter.kernel,
           let outputImage = HDRVisionVideoFilter.applyKernel(kernel, to: sourceImage, settings: settings) {
            ciContext.render(outputImage, to: outputPixelBuffer)
            HDRVisionVideoFilter.noteFrameProcessed()
            request.finish(withComposedVideoFrame: outputPixelBuffer)
        } else {
            // 内核没加载或应用失败：把原帧原样渲染到输出缓冲，直通。
            ciContext.render(sourceImage, to: outputPixelBuffer)
            HDRVisionVideoFilter.noteFramePassedThrough()
            request.finish(withComposedVideoFrame: outputPixelBuffer)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        // 渲染是同步的（startRequest 内完成），没有挂起的异步工作可取消。
    }
}
