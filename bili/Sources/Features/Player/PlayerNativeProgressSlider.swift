import SwiftUI

enum PlayerNativeProgressStyle: Equatable {
    case standard
    case telegram
}

struct PlayerNativeProgressSlider: View {
    @ObservedObject var clock: PlayerPlaybackClock
    let canSeek: Bool
    let sliderVisualScale: CGFloat
    let style: PlayerNativeProgressStyle
    let onScrubStart: (Double) -> Void
    let onScrubChanged: (Double) -> Void
    let onScrubEnded: (Double) -> Void
    let onScrubCancelled: () -> Void

    @State private var scrubbingState = PlayerNativeProgressScrubbingState()
    @State private var scrubStartTask: Task<Void, Never>?
    @State private var scrubChangeTask: Task<Void, Never>?
    @State private var pendingScrubChangeProgress: Double?
    @State private var hasDeliveredScrubStart = false
    private let scrubChangeReportDelta = 0.004
    private let scrubStartFeedbackDelayNanoseconds: UInt64 = 20_000_000
    private let scrubChangeFeedbackDelayNanoseconds: UInt64 = 8_000_000

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                progressTrack(width: proxy.size.width)

                if style == .standard {
                    standardThumb
                        .biliPlayerClearGlass(interactive: false, in: Circle())
                        .offset(x: thumbLeadingOffset(width: proxy.size.width))
                        .opacity(scrubbingState.isEditing ? 1 : 0.001)
                        .allowsHitTesting(false)
                }

                // 拖动与时长解耦：手势只看播放器能不能 seek（点播/直播），不看时长是否
                // 已知。无论视频能不能加载、时长是否读到，thumb 都要跟手；松手 seek
                // 那一下才由 viewModel/引擎决定（时长未知时引擎返回 nil，不会 seek 到 0）。
                // 之前这里用 effectiveCanSeek（canSeek && duration > 0），时长一丢
                // 整个进度条就被禁用、拖动中还会被强制取消，看起来像“卡死”。
                PlayerNativeProgressGestureCaptureLayer(
                    isEnabled: canSeek,
                    onScrubChanged: { progress in
                        updateScrub(at: progress)
                    },
                    onScrubEnded: { progress in
                        finishScrub(at: progress)
                    }
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        // 拖动与时长解耦：只在播放器本身不能 seek 时禁用；时长瞬时丢失不禁用、
        // 不取消进行中的拖动（之前用 effectiveCanSeek，时长一丢就禁、拖动中翻 false
        // 还强制取消，进度条看起来像卡死）。
        .disabled(!canSeek)
        .onChange(of: canSeek) { _, canSeek in
            if !canSeek {
                cancelPendingScrubStart()
                cancelPendingScrubChange()
                if scrubbingState.isEditing {
                    onScrubCancelled()
                }
                scrubbingState.reset()
            }
        }
        .onDisappear {
            cancelPendingScrubStart()
            cancelPendingScrubChange()
        }
        .transaction { transaction in
            transaction.animation = nil
        }
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(Int((displayProgress * 100).rounded()))%")
    }

    private func progressTrack(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(style == .telegram ? Color.clear : Color.white.opacity(0.28))
                .frame(width: width, height: trackHeight)

            // 缓存条：浅色，已缓存到的位置（底轨之上、已播之下）。拖动时不动，
            // 只跟 clock.bufferedProgress 走；已播的 0.96 白会盖住它，三段分明。
            if style == .telegram {
                Rectangle()
                    .fill(.white.opacity(0.5))
                    .frame(width: width * CGFloat(clock.bufferedProgress), height: trackHeight)
            } else {
                Capsule()
                    .fill(.white.opacity(0.5))
                    .frame(width: width * CGFloat(clock.bufferedProgress), height: trackHeight)
            }

            if style == .telegram {
                Rectangle()
                    .fill(.white)
                    .frame(width: width * CGFloat(displayProgress), height: trackHeight)
            } else {
                Capsule()
                    .fill(.white.opacity(0.96))
                    .frame(width: width * CGFloat(displayProgress), height: trackHeight)
            }
        }
        .frame(width: width, height: trackHeight)
        .clipShape(Capsule())
        .modifier(TelegramProgressTrackGlassModifier(
            isEnabled: style == .telegram,
            isInteractive: scrubbingState.isEditing
        ))
        .allowsHitTesting(false)
    }

    private var standardThumb: some View {
        Circle()
            .fill(.white.opacity(0.16))
            .frame(width: thumbWidth, height: thumbHeight)
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.62), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.24), radius: 3, y: 1)
    }

    private var trackHeight: CGFloat {
        if style == .telegram {
            return scrubbingState.isEditing ? 10 : 8
        }
        return max(2, 2.5 * sliderVisualScale)
    }

    private var thumbWidth: CGFloat {
        return 16 * min(max(sliderVisualScale / 0.82, 1), 1.15)
    }

    private var thumbHeight: CGFloat {
        return thumbWidth
    }

    private func thumbLeadingOffset(width: CGFloat) -> CGFloat {
        Self.thumbLeadingOffset(
            progress: displayProgress,
            width: width,
            thumbDiameter: thumbWidth
        )
    }

    static func thumbLeadingOffset(
        progress: Double,
        width: CGFloat,
        thumbDiameter: CGFloat
    ) -> CGFloat {
        guard width > 0, thumbDiameter > 0 else { return 0 }
        let clampedProgress = min(max(progress, 0), 1)
        let proposedOffset = width * CGFloat(clampedProgress) - thumbDiameter / 2
        return min(max(proposedOffset, 0), max(width - thumbDiameter, 0))
    }

    private var displayProgress: Double {
        min(max(scrubbingState.isEditing ? scrubbingState.editingProgress : clock.displayProgress, 0), 1)
    }

    // 注意：这里故意不用“canSeek && duration > 0”做门禁。拖动只看播放器能不能
    // seek，时长是否已知不影响 thumb 跟手；松手 seek 时 viewModel/引擎会自己
    // 处理时长未知的情况（引擎 duration <= 0 时返回 nil，不会 seek 到 0）。

    private func updateScrub(at progress: Double) {
        let didBegin = beginScrub(at: progress)
        if !didBegin, hasDeliveredScrubStart {
            scheduleScrubChanged(progress)
        }
    }

    @discardableResult
    private func beginScrub(at progress: Double) -> Bool {
        var didBegin = false
        scrubbingState.beginScrub(
            at: progress,
            canSeek: canSeek,
            onScrubStart: { progress in
                didBegin = true
                scheduleScrubStart(at: progress)
            }
        )
        return didBegin
    }

    private func scheduleScrubStart(at progress: Double) {
        cancelPendingScrubStart()
        scrubStartTask = Task { @MainActor in
            // Give SwiftUI one display frame to reveal the thumb before player work begins.
            try? await Task.sleep(nanoseconds: scrubStartFeedbackDelayNanoseconds)
            guard !Task.isCancelled, scrubbingState.isEditing else { return }
            onScrubStart(progress)
            guard !Task.isCancelled, scrubbingState.isEditing else { return }
            hasDeliveredScrubStart = true
            scrubStartTask = nil
            scheduleScrubChanged(scrubbingState.editingProgress)
        }
    }

    private func finishScrub(at progress: Double) {
        let pendingStartProgress = scrubbingState.editingProgress
        scrubStartTask?.cancel()
        scrubStartTask = nil
        cancelPendingScrubChange()
        if scrubbingState.isEditing, !hasDeliveredScrubStart {
            onScrubStart(pendingStartProgress)
        }
        hasDeliveredScrubStart = false
        scrubbingState.finishScrub(
            at: progress,
            canSeek: canSeek,
            onScrubEnded: onScrubEnded
        )
    }

    private func cancelPendingScrubStart() {
        scrubStartTask?.cancel()
        scrubStartTask = nil
        hasDeliveredScrubStart = false
    }

    private func scheduleScrubChanged(_ progress: Double) {
        guard scrubbingState.shouldReportChange(
            at: progress,
            minimumDelta: scrubChangeReportDelta
        ) else { return }
        pendingScrubChangeProgress = progress
        guard scrubChangeTask == nil else { return }
        scrubChangeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: scrubChangeFeedbackDelayNanoseconds)
            guard
                !Task.isCancelled,
                scrubbingState.isEditing,
                let progress = pendingScrubChangeProgress
            else { return }
            pendingScrubChangeProgress = nil
            scrubChangeTask = nil
            onScrubChanged(progress)
        }
    }

    private func cancelPendingScrubChange() {
        scrubChangeTask?.cancel()
        scrubChangeTask = nil
        pendingScrubChangeProgress = nil
    }
}

private struct TelegramProgressTrackGlassModifier: ViewModifier {
    let isEnabled: Bool
    let isInteractive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.biliPlayerClearGlass(interactive: isInteractive, in: Capsule())
        } else {
            content
        }
    }
}
