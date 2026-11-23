import Foundation

extension HomeFeedMediaPreloadCoordinator {
    func updateImagePrefetchProfile(_ profile: HomeFeedCoverPrefetchProfile) {
        guard imagePrefetchProfile != profile else { return }
        imagePrefetchProfile = profile
        imageLookaheadTask?.cancel()
        imageLookaheadTask = nil
        imageLookaheadRequest = nil
    }

    func scheduleImagePrefetch(for videos: [VideoItem]) {
        imagePrefetchTask?.cancel()
        resetImageLookaheadIfNeeded(for: videos)
        // 第 16 轮：内存警告后 30 秒内不调度封面预取（HomeFeedPreloadMemoryWarningPause），
        // 避免刚清完缓存又立刻下满。已取消的旧任务不再重建；暂停期过了下次调度自动恢复。
        guard !HomeFeedPreloadMemoryWarningPause.shared.isPaused else {
            imagePrefetchTask = nil
            return
        }
        let environment = PlaybackEnvironment.current
        let layout = libraryStore.homeFeedLayout
        let prefetchLimit = HomeFeedImagePrefetchPolicy.initialPrefetchLimit(
            layout: layout,
            isConservative: environment.shouldPreferConservativePlayback
        )
        let prefetchPlan = HomeFeedImagePrefetchPlan.make(
            for: videos,
            profile: resolvedImagePrefetchProfile(for: layout),
            limit: prefetchLimit
        )

        guard !prefetchPlan.coverSources.isEmpty else { return }
        let coverSourcesToPrefetch = prefetchPlan.coverSources
        let coverTargetPixelSize = prefetchPlan.coverTargetPixelSize
        imagePrefetchTask = Task(priority: .utility) {
            await RemoteImageCache.shared.prefetch(
                coverSourcesToPrefetch,
                targetPixelSize: coverTargetPixelSize,
                maximumConcurrentLoads: HomeFeedImagePrefetchPolicy.maximumConcurrentLoads(
                    isConservative: environment.shouldPreferConservativePlayback
                )
            )
        }
    }

    func scheduleImageLookahead(for videos: [VideoItem], visibleIndex: Int) {
        guard videos.indices.contains(visibleIndex) else { return }
        resetImageLookaheadIfNeeded(for: videos)
        // 第 16 轮：内存警告后 30 秒内不调度封面 lookahead（HomeFeedPreloadMemoryWarningPause）。
        // 已在跑的任务不受影响（其下载由抑制门的内存警告作用域拦住，暂停期过后继续）；
        // 暂停期过了下次调度自动恢复。
        guard !HomeFeedPreloadMemoryWarningPause.shared.isPaused else { return }

        let environment = PlaybackEnvironment.current
        let layout = libraryStore.homeFeedLayout
        let startIndex = HomeFeedImagePrefetchPolicy.lookaheadStartIndex(
            visibleIndex: visibleIndex,
            layout: layout
        )
        guard startIndex < videos.count else { return }

        let profile = resolvedImagePrefetchProfile(for: layout)
        let request = HomeFeedImageLookaheadRequest(
            feedRootBVID: imageLookaheadFeedRootBVID,
            startIndex: startIndex,
            profile: profile
        )
        guard request != imageLookaheadRequest else { return }

        let prefetchPlan = HomeFeedImagePrefetchPlan.make(
            for: videos,
            profile: profile,
            startIndex: startIndex,
            limit: HomeFeedImagePrefetchPolicy.lookaheadLimit(
                layout: layout,
                isConservative: environment.shouldPreferConservativePlayback
            )
        )
        guard !prefetchPlan.coverSources.isEmpty else { return }

        imageLookaheadTask?.cancel()
        imageLookaheadRequest = request
        let coverSources = prefetchPlan.coverSources
        let targetPixelSize = prefetchPlan.coverTargetPixelSize
        let maximumConcurrentLoads = HomeFeedImagePrefetchPolicy.maximumConcurrentLoads(
            isConservative: environment.shouldPreferConservativePlayback
        )
        imageLookaheadTask = Task(priority: .utility) { [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: HomeFeedImagePrefetchPolicy.lookaheadDebounceNanoseconds()
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await RemoteImageCache.shared.prefetch(
                coverSources,
                targetPixelSize: targetPixelSize,
                maximumConcurrentLoads: maximumConcurrentLoads
            )
            guard !Task.isCancelled,
                  let self,
                  self.imageLookaheadRequest == request
            else { return }
            self.imageLookaheadTask = nil
        }
    }

    func resolvedImagePrefetchProfile(for layout: HomeFeedLayout) -> HomeFeedCoverPrefetchProfile {
        imagePrefetchProfile ?? HomeFeedCoverPrefetchProfile.fallback(for: layout)
    }

    private func resetImageLookaheadIfNeeded(for videos: [VideoItem]) {
        let feedRootBVID = videos.first?.bvid ?? ""
        guard feedRootBVID != imageLookaheadFeedRootBVID else { return }
        imageLookaheadTask?.cancel()
        imageLookaheadTask = nil
        imageLookaheadRequest = nil
        imageLookaheadFeedRootBVID = feedRootBVID
    }
}
