import Foundation

nonisolated enum HomeFeedImagePrefetchPolicy {
    static func initialPrefetchLimit(layout: HomeFeedLayout, isConservative: Bool) -> Int {
        guard !isConservative else { return 3 }
        return usesDoubleColumn(layout) ? 8 : 6
    }

    static func maximumConcurrentLoads(isConservative: Bool) -> Int {
        isConservative ? 1 : 3
    }

    static func initialPrewarmDeadlineNanoseconds(isConservative: Bool) -> UInt64 {
        isConservative ? 260_000_000 : 380_000_000
    }

    static func lookaheadStartIndex(visibleIndex: Int, layout: HomeFeedLayout) -> Int {
        // 120Hz：预取窗口加大，快滑时新卡片更大概率已有图，减少滚动中途现加载
        // + 弹入（弹入正好撞在 8.3ms 帧预算上）。双列提前 8 张、单列提前 6 张。
        let lead = usesDoubleColumn(layout) ? 8 : 6
        return max(0, visibleIndex + lead)
    }

    static func lookaheadLimit(layout: HomeFeedLayout, isConservative: Bool) -> Int {
        guard !isConservative else { return 3 }
        return usesDoubleColumn(layout) ? 10 : 8
    }

    static func lookaheadDebounceNanoseconds() -> UInt64 {
        100_000_000
    }

    private static func usesDoubleColumn(_ layout: HomeFeedLayout) -> Bool {
        switch layout {
        case .doubleColumn, .borderedDoubleColumn:
            true
        case .singleColumn, .borderedSingleColumn:
            false
        }
    }
}
