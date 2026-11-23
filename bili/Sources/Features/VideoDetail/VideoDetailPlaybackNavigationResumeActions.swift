import Foundation

extension VideoDetailViewModel {
    func markRelatedVideoNavigation() {
        isAwaitingRelatedVideoReturnPlayback = true
    }

    func resumePlaybackAfterCoveredNavigationIfNeeded() async {
        guard isPlaybackInvalidatedForNavigation || isPlaybackTerminatedForNavigation else { return }
        navigationState.isPlaybackStopPending = false
        isPlaybackInvalidatedForNavigation = false
        isPlaybackTerminatedForNavigation = false
        // 第 16 轮：本页不再挂起，从保留深度表里移除；同时清掉“等相关视频返回”
        // 标志——放在 if let player 之前，让被逐出（播放器已释放）的页走 load()
        // 重建播放器时也能自动恢复：restoreStablePlayerForLoadedDetail 按该标志
        // 决定是否自动播放，不清的话重建后只会显示手动播放提示。
        // 注意：不要在这里清 pendingNavigationResumeTime（重建播放器要用它续播，
        // restoreStablePlayerForLoadedDetail 用完自己会清）。
        SuspendedDetailPlaybackRegistry.shared.unregister(self)
        isAwaitingRelatedVideoReturnPlayback = false

        if let player = stablePlayerViewModel {
            player.setRelatedVideoReturnPlaybackPrompt(false)
            _ = player.restoreAudioAfterCancelledNavigation()
            clearPendingNavigationResumeState()
            return
        }

        await load()
    }

    private func clearPendingNavigationResumeState() {
        shouldResumePlaybackAfterCancelledNavigation = false
        pendingNavigationResumeTime = nil
        hasPendingNavigationInterruption = false
    }
}
