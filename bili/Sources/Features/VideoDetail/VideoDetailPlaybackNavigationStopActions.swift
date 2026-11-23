import Foundation
import UIKit

extension VideoDetailViewModel {
    func markExitingVideoDetailRoute() {
        isExitingVideoDetailRoute = true
    }

    func clearExitingVideoDetailRoute() {
        isExitingVideoDetailRoute = false
    }

    @discardableResult
    func handoffToSystemMiniPlayerIfEligible(
        preferredFrameInWindow: CGRect? = nil,
        preferredWindow: UIWindow? = nil
    ) -> Bool {
        guard !isPlaybackInvalidatedForNavigation else { return false }
        guard !didTransferToSystemMiniPlayer else { return false }
        if !isExitingVideoDetailRoute, isRouteRemovedFromNavigationStack?() == true {
            isExitingVideoDetailRoute = true
        }
        guard isExitingVideoDetailRoute else { return false }
        guard !isAwaitingRelatedVideoReturnPlayback else { return false }
        guard libraryStore.autoPictureInPictureOnExitEnabled else { return false }
        guard playbackOptions != .performanceTest else { return false }
        guard playbackContentMode == .video else { return false }
        guard let playerViewModel = stablePlayerViewModel,
              SystemMiniPlayerCoordinator.shared.canStartMiniPlayer(for: playerViewModel)
        else { return false }

        let session = SystemMiniPlayerCoordinator.RetainedSession(
            video: detail,
            selectedCID: selectedCID,
            playVariants: playVariants,
            selectedPlayVariant: selectedPlayVariant,
            currentPlayURLData: currentPlayURLData,
            isDanmakuEnabled: isDanmakuEnabled,
            hasResolvedDetailMetadata: hasResolvedDetailMetadata,
            stablePlayerIdentity: stablePlayerIdentity,
            playerViewModel: playerViewModel,
            recordsPlaybackHistory: playbackOptions.recordsPlaybackHistory,
            api: api,
            libraryStore: libraryStore
        )
        guard SystemMiniPlayerCoordinator.shared.beginMiniPlayer(
            with: session,
            preferredFrameInWindow: preferredFrameInWindow,
            preferredWindow: preferredWindow
        ) else {
            return false
        }

        didTransferToSystemMiniPlayer = true
        isPlaybackInvalidatedForNavigation = true
        isPlaybackTerminatedForNavigation = true
        navigationState.isPlaybackStopPending = false

        // Freeze the last video frame on the outgoing detail page while it
        // slides away so transferring the live `AVPlayerLayer` never flashes black.
        if let snapshot = playerViewModel.makePlaybackTransitionSnapshot() {
            playbackTransitionState.snapshot = snapshot
            playbackTransitionState.fallbackCoverURL = playbackTransitionCoverURL()
            playbackTransitionState.opacity = 1
        }

        stablePlayerViewModel = nil
        stablePlayerIdentity = nil
        stablePlayerErrorCancellable = nil
        stablePlayerFirstFrameCancellable = nil
        syncPlayerIdentityRenderStore()
        clearPlaybackTransitionPlayer()
        cancelPlaybackWorkForNavigation()
        resetPlaybackRecoveryStateForNavigation()
        return true
    }

    func stopPlaybackForNavigation() {
        guard !isPlaybackInvalidatedForNavigation else { return }
        if handoffToSystemMiniPlayerIfEligible() {
            return
        }
        let resumeTime = currentPlaybackResumeTime()
        capturePlaybackStateForNavigation(resumeTime: resumeTime)
        flushPlaybackProgressForNavigation(resumeTime: resumeTime)
        isPlaybackTerminatedForNavigation = true
        isPlaybackInvalidatedForNavigation = true

        // A related-video push keeps this detail page alive underneath the new
        // route. Suspend the existing engine, but retain its media and model so
        // popping back does not trigger a full detail/playback reload.
        if isAwaitingRelatedVideoReturnPlayback {
            stablePlayerViewModel?.pauseForNavigation()
            // 第 16 轮：挂起页登记进保留深度表；超过最近 2 个时，最旧的挂起页
            // 延迟 400ms 后释放播放器（与 pop 的 teardown 同款延迟，避免在 push
            // 动画里做 replaceCurrentItem + HLS 桥 teardown 的主线程重活）。
            // 返回最近一个视频仍即时恢复；更深的旧页返回时重载。
            SuspendedDetailPlaybackRegistry.shared.register(self)
            for page in SuspendedDetailPlaybackRegistry.shared.takePagesBeyondRetainedDepth() {
                scheduleReleaseSuspendedPlaybackForMemory(page)
            }
            return
        }

        stablePlayerViewModel?.pauseForNavigation()
        navigationState.isPlaybackStopPending = true
    }

    /// 第 16 轮：给一个已被逐出保留深度的挂起页排期释放播放器（延迟 400ms）。
    /// 与 pop 的 teardown 同款延迟：replaceCurrentItem + HLS 桥 teardown 是
    /// 主线程上的一次性重活，不要在 push 动画里做。400ms 后才真正释放，
    /// 内存晚 400ms 回落，不影响总量上限。
    private func scheduleReleaseSuspendedPlaybackForMemory(_ page: VideoDetailViewModel) {
        Task { @MainActor [weak page] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let page else { return }
            page.releaseSuspendedPlaybackForMemoryIfNeeded()
        }
    }

    /// 第 16 轮：释放本页被挂起的播放器（仅当本页仍在等相关视频返回时）。
    /// 复用 finishPlaybackStopAfterNavigationTransition 同款拆播放器路径
    ///（stopStablePlaybackForNavigation：player stop + 置空），只保留轻量模型
    ///（详情/评论/相关数据都在 VideoDetailViewModel 上），返回时经 load()
    /// → restoreStablePlayerForLoadedDetail() 重建播放器、按
    /// pendingNavigationResumeTime 续播。
    /// 守卫：若用户已在 400ms 内返回本页（已恢复）、或已交接给 mini-player，
    /// 跳过释放——前者媒体还在、即时恢复，后者播放器已不在本页手里。
    func releaseSuspendedPlaybackForMemoryIfNeeded() {
        guard isPlaybackInvalidatedForNavigation,
              isAwaitingRelatedVideoReturnPlayback,
              !didTransferToSystemMiniPlayer,
              stablePlayerViewModel != nil
        else { return }
        stopStablePlaybackForNavigation()
        SuspendedDetailPlaybackRegistry.shared.unregister(self)
    }

    private func capturePlaybackStateForNavigation(resumeTime: TimeInterval) {
        let suspendedState = stablePlayerViewModel?.pendingNavigationResumeState()
        let bestResumeTime = max(resumeTime, suspendedState?.resumeTime ?? 0)
        pendingNavigationResumeTime = bestResumeTime > 0.25 ? bestResumeTime : nil
        shouldResumePlaybackAfterCancelledNavigation = suspendedState?.shouldResumePlayback
            ?? currentPlaybackIntent()
        videoListenPlaybackSessionStore.removeState(for: detail)
        pendingVideoListenPlaybackSessionState = nil
        hasPendingNavigationInterruption = true
    }

    private func flushPlaybackProgressForNavigation(resumeTime: TimeInterval) {
        guard playbackOptions.recordsPlaybackHistory else { return }
        Self.flushPlaybackHistoryProgress(
            video: detail,
            cid: selectedCID ?? detail.cid,
            resumeTime: resumeTime,
            libraryStore: libraryStore,
            api: api
        )
    }

    static func flushPlaybackHistoryProgress(
        video: VideoItem,
        cid: Int?,
        resumeTime: TimeInterval,
        libraryStore: LibraryStore,
        api: BiliAPIClient
    ) {
        guard !libraryStore.incognitoModeEnabled else { return }
        guard resumeTime.isFinite,
              resumeTime >= TimeInterval(libraryStore.playbackHistorySyncThresholdSeconds)
        else { return }
        let duration = video.duration.map(TimeInterval.init)
        libraryStore.recordPlaybackProgress(
            video: video,
            cid: cid,
            progress: resumeTime,
            duration: duration
        )
        Task {
            try? await api.reportVideoHistory(
                aid: video.aid,
                cid: cid,
                progress: resumeTime,
                duration: duration,
                bvid: video.bvid
            )
        }
    }

    func finishPlaybackStopAfterNavigationTransition() {
        guard navigationState.isPlaybackStopPending else { return }
        navigationState.isPlaybackStopPending = false
        cancelPlaybackWorkForNavigation()
        resetPlaybackLoadingStateForNavigation()
        stopStablePlaybackForNavigation()
        resetPlaybackRecoveryStateForNavigation()
    }

    private func cancelPlaybackWorkForNavigation() {
        cancelVideoListenQueueTasks(resetSession: false)
        cancelSupplementalWork()
        Self.cancelMediaWarmupsPreservingCache()
        cancelRelatedLoad()
        cancelCommentsLoadingTask()
        clearCommentThreadLoads()
        resetDanmakuLoad(clearItems: true)
        detailLoadingTask?.cancel()
        detailLoadingTask = nil
        detailLoadingToken = nil
        cancelSponsorBlockTask()
        sponsorBlockSegments = []
        sponsorBlockIdentity = nil
        renderStoreSyncTask?.cancel()
        renderStoreSyncTask = nil
        pendingRenderStoreSyncs = []
        renderStoreSyncGeneration += 1
    }

    private func resetPlaybackLoadingStateForNavigation() {
        currentPlayURLData = nil
        clearVideoListenAudioVariants()
        selectedPlayVariant = nil
        if state.isLoading {
            state = .idle
        }
        finishPlaybackStartupWaiters(with: nil)
        playURLState = .idle
    }

    private func stopStablePlaybackForNavigation() {
        stablePlayerViewModel?.stop()
        stablePlayerViewModel = nil
        clearPlaybackTransitionPlayer()
        stablePlayerIdentity = nil
        stablePlayerErrorCancellable = nil
        stablePlayerFirstFrameCancellable = nil
        syncPlayerIdentityRenderStore()
    }

    private func resetPlaybackRecoveryStateForNavigation() {
        pendingVideoListenPlaybackIntent = nil
        cancelVideoListenSleepTimer()
        playbackFallbackMessage = nil
        clearManualPlayVariantSelection()
        failedPlayVariantIDs.removeAll()
        playbackRecoveryAttemptCount = 0
        playbackRecoveryCoordinator.reset()
        lastBufferingCDNRefreshCount = 0
        cancelPlaybackRecoveryReloadTask()
        cancelBufferingCDNRefreshTask()
        lastUserSeekAt = nil
        resumeDiagnostics = .none
    }
}
