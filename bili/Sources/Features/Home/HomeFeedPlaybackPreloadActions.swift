import Foundation

extension HomeFeedMediaPreloadCoordinator {
    func schedulePlaybackPreload(for videos: [VideoItem], initialDelay: TimeInterval) {
        playbackPreloadTask?.cancel()
        // 第 16 轮：内存警告后 30 秒内不调度播放预载（HomeFeedPreloadMemoryWarningPause），
        // 避免刚清完缓存又立刻下满。暂停期过了下次调度自动恢复。
        guard !HomeFeedPreloadMemoryWarningPause.shared.isPaused else {
            playbackPreloadTask = nil
            return
        }
        let playbackAdaptationProfile = PlayerPerformanceStore.shared.playbackAdaptationProfile(
            isEnabled: libraryStore.isPlaybackAutoOptimizationEnabled
        )
        let candidateLimit = max(0, min(2, playbackAdaptationProfile.backgroundRoutePlanPreloadLimit))
        guard candidateLimit > 0 else {
            playbackPreloadTask = nil
            return
        }
        let candidates = Array(videos
            .filter { $0.cid != nil && !$0.bvid.isEmpty && !$0.bvid.hasPrefix("av") }
            .prefix(candidateLimit))
        guard !candidates.isEmpty else {
            playbackPreloadTask = nil
            return
        }

        let preferredQuality = libraryStore.effectivePreferredVideoQuality
        let cdnPreference = libraryStore.effectivePlaybackCDNPreference
        playbackPreloadTask = Task(priority: .utility) { [api, cdnPreference] in
            let startupDelay = max(0.05, min(initialDelay, 0.24))
            try? await Task.sleep(nanoseconds: UInt64(startupDelay * 1_000_000_000))
            let foregroundDelay = await ResourceLoadingForegroundPriorityGate.shared
                .backgroundDelayNanoseconds(for: .home)
            if foregroundDelay > 0 {
                try? await Task.sleep(nanoseconds: foregroundDelay)
            }
            guard !Task.isCancelled else { return }
            for (index, video) in candidates.enumerated() {
                guard !Task.isCancelled else { return }
                let isPrimary = index == 0
                await VideoPreloadCenter.shared.updatePlaybackPreferences(
                    preferredQuality: preferredQuality,
                    cdnPreference: cdnPreference,
                    playbackAdaptationProfile: playbackAdaptationProfile
                )
                await VideoPreloadCenter.shared.preloadPlayInfo(
                    video,
                    api: api,
                    preferredQuality: preferredQuality,
                    cdnPreference: cdnPreference,
                    priority: .utility,
                    warmsMedia: true,
                    mediaWarmupMode: isPrimary ? .full : .routePlanOnly,
                    mediaWarmupDelay: isPrimary ? 0 : 0.14,
                    playbackAdaptationProfile: playbackAdaptationProfile,
                    preloadSource: "startup"
                )
                if index < candidates.count - 1 {
                    try? await Task.sleep(nanoseconds: 650_000_000)
                }
            }
        }
    }
}
