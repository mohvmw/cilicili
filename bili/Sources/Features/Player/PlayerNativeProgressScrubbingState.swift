import SwiftUI

struct PlayerNativeProgressScrubbingState {
    var editingProgress = 0.0
    var isEditing = false
    var hasReportedScrubStart = false
    private var lastReportedChangeProgress: Double?

    mutating func beginScrub(
        at progress: Double,
        canSeek: Bool,
        onScrubStart: (Double) -> Void
    ) {
        guard canSeek else { return }
        let clampedProgress = min(max(progress, 0), 1)
        if !hasReportedScrubStart {
            hasReportedScrubStart = true
            isEditing = true
            editingProgress = clampedProgress
            lastReportedChangeProgress = nil
            onScrubStart(clampedProgress)
        } else {
            isEditing = true
            editingProgress = clampedProgress
        }
    }

    mutating func finishScrub(
        at progress: Double,
        canSeek: Bool,
        onScrubEnded: (Double) -> Void
    ) {
        guard canSeek else { return }
        let clampedProgress = min(max(progress, 0), 1)
        editingProgress = clampedProgress
        hasReportedScrubStart = false
        // 先写时钟再清“编辑中”标志：onScrubEnded（→ seekAfterSliderCommit）把时钟
        // 写到目标，之后 displayProgress 从 editingProgress 切到 clock.displayProgress
        // 时时钟已经是目标值。之前顺序反了——isEditing 先变 false，显示立刻切回
        // 还没更新的时钟（旧播放点），进度条先弹回旧位置、再弹回拖动位置。
        // seekAfterSliderCommit 不读 scrubbingState.isEditing（它是 view 局部的），
        // 调换无副作用。
        onScrubEnded(clampedProgress)
        isEditing = false
        lastReportedChangeProgress = nil
    }

    mutating func shouldReportChange(at progress: Double, minimumDelta: Double) -> Bool {
        let clampedProgress = min(max(progress, 0), 1)
        guard let lastReportedChangeProgress else {
            self.lastReportedChangeProgress = clampedProgress
            return true
        }
        guard abs(clampedProgress - lastReportedChangeProgress) >= minimumDelta else {
            return false
        }
        self.lastReportedChangeProgress = clampedProgress
        return true
    }

    mutating func reset() {
        hasReportedScrubStart = false
        isEditing = false
        lastReportedChangeProgress = nil
    }
}
