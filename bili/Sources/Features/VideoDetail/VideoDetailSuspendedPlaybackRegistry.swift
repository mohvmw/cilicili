import Foundation

/// 第 16 轮：被挂起的详情页登记表（相关视频 push 后保留在导航栈下、只挂起不释放的页）。
///
/// 背景：相关视频 push 时旧页只挂起不释放（`stopPlaybackForNavigation` 的设计意图），
/// 连点相关视频会让旧详情页（含 AVPlayer + AVPlayerItem + 解码缓冲）在导航栈里
/// 越积越多，内存随连点数线性涨。本表限制保留深度：只保留最近 N 个挂起页的
/// 播放器，更深的旧页延迟释放播放器、返回时重载（只保留轻量模型——详情/评论/
/// 相关数据都在 VideoDetailViewModel 上，播放器重建走既有的 load() 路径）。
///
/// 只存弱引用：页被 pop 掉、deinit 后自动失效，不阻止释放。
@MainActor
final class SuspendedDetailPlaybackRegistry {
    static let shared = SuspendedDetailPlaybackRegistry()

    /// 最多保留几个挂起页的播放器。超过这个数，最旧的挂起页释放播放器。
    /// N=2：返回最近一个视频（栈顶下一层）仍即时恢复、不重新加载；
    /// 更深的旧页返回时重载（代价：重新加载一次，换内存）。
    static let maxRetainedSuspendedPages = 2

    private struct WeakPage {
        weak var page: VideoDetailViewModel?
    }

    private var pages: [WeakPage] = []

    private init() {}

    func register(_ page: VideoDetailViewModel) {
        cleanup()
        guard !pages.contains(where: { $0.page === page }) else { return }
        pages.append(WeakPage(page: page))
    }

    func unregister(_ page: VideoDetailViewModel) {
        pages.removeAll { $0.page == nil || $0.page === page }
    }

    /// 取出超过保留深度的最旧挂起页（按挂起顺序）。调用方负责在延迟后释放
    /// 它们的播放器；本方法在返回时就把它们移出登记表，避免重复选中。
    /// （实际释放是延迟的——若用户在 400ms 内返回该页，释放任务里的
    /// “仍挂起”检查会跳过，媒体还在，即时恢复。）
    func takePagesBeyondRetainedDepth() -> [VideoDetailViewModel] {
        cleanup()
        guard pages.count > Self.maxRetainedSuspendedPages else { return [] }
        let excessCount = pages.count - Self.maxRetainedSuspendedPages
        let evicted = Array(pages.prefix(excessCount).compactMap(\.page))
        pages.removeFirst(excessCount)
        return evicted
    }

    private func cleanup() {
        pages.removeAll { $0.page == nil }
    }
}
