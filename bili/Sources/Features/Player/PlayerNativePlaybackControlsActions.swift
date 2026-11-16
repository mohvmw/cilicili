import Foundation

struct PlayerNativePlaybackControlsActions {
    let onScrubStart: (Double) -> Void
    let onScrubChanged: (Double) -> Void
    let onScrubEnded: (Double) -> Void
    let onScrubCancelled: () -> Void
    let onTogglePlayback: () -> Void
    let onToggleDanmaku: () -> Void
    let onToggleFullscreen: () -> Void
    /// HDR 视界开关（无提供方时为空操作，按钮也不显示）。
    var onToggleHDR: () -> Void = {}
}
