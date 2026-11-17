import SwiftUI

struct PlayerNativePlaybackControls: View {
    let clock: PlayerPlaybackClock
    let metrics: PlayerNativeControlMetrics
    let layout: BiliPlayerControlLayout
    let canSeek: Bool
    let isPlaying: Bool
    let isDanmakuEnabled: Bool
    let showsDanmakuButton: Bool
    let isHDREnabled: Bool = false
    let showsHDRButton: Bool = false
    let canToggleFullscreen: Bool
    let isFullscreenActive: Bool
    let controlsAccessory: AnyView?
    let controlsCenterAccessory: AnyView?
    let progressStyle: PlayerNativeProgressStyle
    let actions: PlayerNativePlaybackControlsActions

    /// 显式初始化器：`let` 带默认值的属性不会进入 Swift 自动合成的 memberwise init，
    /// 不写这个初始化器，调用方传 `isHDREnabled`/`showsHDRButton` 会报 extra arguments。
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
