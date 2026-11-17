import SwiftUI

struct PlayerNativeControlButtonRow: View {
    let clock: PlayerPlaybackClock
    let metrics: PlayerNativeControlMetrics
    let layout: BiliPlayerControlLayout
    let isPlaying: Bool
    let isDanmakuEnabled: Bool
    let showsDanmakuButton: Bool
    var isHDREnabled: Bool = false
    var showsHDRButton: Bool = false
    let canToggleFullscreen: Bool
    let isFullscreenActive: Bool
    let controlsAccessory: AnyView?
    let controlsCenterAccessory: AnyView?
    let actions: PlayerNativePlaybackControlsActions

    /// 显式初始化器：`let` 带默认值的属性不会进入 Swift 自动合成的 memberwise init，
    /// 且带默认值的 `let` 也不能在 init 里再赋值（immutable value may only be initialized once），
    /// 所以这两个 HDR 属性用 `var`，并由这里统一赋值。
    init(
        clock: PlayerPlaybackClock,
        metrics: PlayerNativeControlMetrics,
        layout: BiliPlayerControlLayout,
        isPlaying: Bool,
        isDanmakuEnabled: Bool,
        showsDanmakuButton: Bool,
        isHDREnabled: Bool = false,
        showsHDRButton: Bool = false,
        canToggleFullscreen: Bool,
        isFullscreenActive: Bool,
        controlsAccessory: AnyView?,
        controlsCenterAccessory: AnyView?,
        actions: PlayerNativePlaybackControlsActions
    ) {
        self.clock = clock
        self.metrics = metrics
        self.layout = layout
        self.isPlaying = isPlaying
        self.isDanmakuEnabled = isDanmakuEnabled
        self.showsDanmakuButton = showsDanmakuButton
        self.isHDREnabled = isHDREnabled
        self.showsHDRButton = showsHDRButton
        self.canToggleFullscreen = canToggleFullscreen
        self.isFullscreenActive = isFullscreenActive
        self.controlsAccessory = controlsAccessory
        self.controlsCenterAccessory = controlsCenterAccessory
        self.actions = actions
    }

    var body: some View {
        ZStack {
            HStack(spacing: metrics.controlSpacing) {
                if layout.showsPlaybackToggle {
                    PlayerNativeGlassIconButton(
                        systemName: isPlaying ? "pause.fill" : "play.fill",
                        accessibilityLabel: isPlaying ? "暂停" : "播放",
                        accessibilityIdentifier: "ui.player.playback.toggle",
                        metrics: metrics,
                        action: actions.onTogglePlayback
                    )
                }

                if layout.showsTimeLabel {
                    PlayerNativeTimeLabel(clock: clock, metrics: metrics)
                        .frame(
                            width: metrics.timeLabelWidth,
                            height: metrics.controlHeight
                        )
                        .biliPlayerClearGlass(
                            interactive: false,
                            in: Capsule(),
                            isEnabled: true
                        )
                }

                if layout.isLive, let controlsAccessory {
                    controlsAccessory
                        .frame(height: metrics.controlHeight)
                }

                Spacer(minLength: 0)

                if !layout.isLive, let controlsAccessory {
                    controlsAccessory
                        .frame(height: metrics.controlHeight)
                }

                if showsHDRButton {
                    PlayerNativeGlassIconButton(
                        systemName: hdrControlSymbol,
                        accessibilityLabel: "HDR 增强",
                        accessibilityIdentifier: "ui.player.hdr.toggle",
                        metrics: metrics,
                        action: actions.onToggleHDR
                    )
                }

                if showsDanmakuButton {
                    PlayerNativeGlassIconButton(
                        systemName: danmakuControlSymbol,
                        accessibilityLabel: "弹幕设置",
                        accessibilityIdentifier: "ui.player.danmaku.toggle",
                        metrics: metrics,
                        action: actions.onToggleDanmaku
                    )
                }

                if canToggleFullscreen {
                    PlayerNativeGlassIconButton(
                        systemName: isFullscreenActive ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        accessibilityLabel: isFullscreenActive ? "退出全屏" : "全屏",
                        accessibilityIdentifier: "ui.player.fullscreen.toggle",
                        metrics: metrics,
                        action: actions.onToggleFullscreen
                    )
                }
            }

            if let controlsCenterAccessory {
                controlsCenterAccessory
                    .frame(height: metrics.controlHeight)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: metrics.controlHeight)
    }

    private var danmakuControlSymbol: String {
        layout.isLive
            ? "slider.horizontal.3"
            : (isDanmakuEnabled ? "text.bubble.fill" : "text.bubble")
    }

    private var hdrControlSymbol: String {
        isHDREnabled ? "sun.max.fill" : "sun.max"
    }
}
