import SwiftUI

struct PlayerNativePlaybackControls: View {
    let clock: PlayerPlaybackClock
    let metrics: PlayerNativeControlMetrics
    let layout: BiliPlayerControlLayout
    let canSeek: Bool
    let isPlaying: Bool
    let isDanmakuEnabled: Bool
    let showsDanmakuButton: Bool
    var isHDREnabled: Bool = false
    var showsHDRButton: Bool = false
    let canToggleFullscreen: Bool
    let isFullscreenActive: Bool
    let controlsAccessory: AnyView?
    let controlsCenterAccessory: AnyView?
    let progressStyle: PlayerNativeProgressStyle
    let actions: PlayerNativePlaybackControlsActions

    /// 显式初始化器：`let` 带默认值的属性不会进入 Swift 自动合成的 memberwise init，
    /// 且带默认值的 `let` 也不能在 init 里再赋值（immutable value may only be initialized once），
    /// 所以这两个 HDR 属性用 `var`，并由这里统一赋值。
    init(
        clock: PlayerPlaybackClock,
        metrics: PlayerNativeControlMetrics,
        layout: BiliPlayerControlLayout,
        canSeek: Bool,
        isPlaying: Bool,
        isDanmakuEnabled: Bool,
        showsDanmakuButton: Bool,
        isHDREnabled: Bool = false,
        showsHDRButton: Bool = false,
        canToggleFullscreen: Bool,
        isFullscreenActive: Bool,
        controlsAccessory: AnyView?,
        controlsCenterAccessory: AnyView?,
        progressStyle: PlayerNativeProgressStyle,
        actions: PlayerNativePlaybackControlsActions
    ) {
        self.clock = clock
        self.metrics = metrics
        self.layout = layout
        self.canSeek = canSeek
        self.isPlaying = isPlaying
        self.isDanmakuEnabled = isDanmakuEnabled
        self.showsDanmakuButton = showsDanmakuButton
        self.isHDREnabled = isHDREnabled
        self.showsHDRButton = showsHDRButton
        self.canToggleFullscreen = canToggleFullscreen
        self.isFullscreenActive = isFullscreenActive
        self.controlsAccessory = controlsAccessory
        self.controlsCenterAccessory = controlsCenterAccessory
        self.progressStyle = progressStyle
        self.actions = actions
    }

    var body: some View {
        GlassEffectContainer(spacing: metrics.groupSpacing) {
            VStack(spacing: metrics.stackSpacing) {
                if layout.showsProgress {
                    PlayerNativeProgressSection(
                        metrics: metrics,
                        clock: clock,
                        canSeek: canSeek,
                        sliderVisualScale: metrics.sliderVisualScale,
                        style: progressStyle,
                        onScrubStart: actions.onScrubStart,
                        onScrubChanged: actions.onScrubChanged,
                        onScrubEnded: actions.onScrubEnded,
                        onScrubCancelled: actions.onScrubCancelled
                    )
                    .id(ObjectIdentifier(clock))
                }

                PlayerNativeControlButtonRow(
                    clock: clock,
                    metrics: metrics,
                    layout: layout,
                    isPlaying: isPlaying,
                    isDanmakuEnabled: isDanmakuEnabled,
                    showsDanmakuButton: showsDanmakuButton,
                    isHDREnabled: isHDREnabled,
                    showsHDRButton: showsHDRButton,
                    canToggleFullscreen: canToggleFullscreen,
                    isFullscreenActive: isFullscreenActive,
                    controlsAccessory: controlsAccessory,
                    controlsCenterAccessory: controlsCenterAccessory,
                    actions: actions
                )
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .biliLiquidGlassForeground(shadowOpacity: 0.20)
        .controlSize(.mini)
    }
}
