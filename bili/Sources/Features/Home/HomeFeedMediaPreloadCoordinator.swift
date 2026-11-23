import Foundation

struct HomeFeedImageLookaheadRequest: Equatable {
    let feedRootBVID: String
    let startIndex: Int
    let profile: HomeFeedCoverPrefetchProfile
}

@MainActor
final class HomeFeedMediaPreloadCoordinator {
    let api: BiliAPIClient
    let libraryStore: LibraryStore
    var imagePrefetchTask: Task<Void, Never>?
    var imageLookaheadTask: Task<Void, Never>?
    var playbackPreloadTask: Task<Void, Never>?
    var imagePrefetchProfile: HomeFeedCoverPrefetchProfile?
    var imageLookaheadRequest: HomeFeedImageLookaheadRequest?
    var imageLookaheadFeedRootBVID = ""

    init(api: BiliAPIClient, libraryStore: LibraryStore) {
        self.api = api
        self.libraryStore = libraryStore
    }

    deinit {
        imagePrefetchTask?.cancel()
        imageLookaheadTask?.cancel()
        playbackPreloadTask?.cancel()
    }
}

/// 第 16 轮：内存警告后首页预取暂停的共享状态。
/// AppDelegate 的 applicationDidReceiveMemoryWarning 置上（默认暂停 30 秒），
/// 首页预取协调器在调度封面预取/封面 lookahead/播放预载前读它。
/// @MainActor：读写都在主线程，无需锁。暂停期过了自动恢复，无需显式清除；
/// 重复警告重新计时。只拦“新调度”，在途的封面预取由
/// RemoteImageLoadSuppressionGate 的内存警告作用域拦住（waitUntilAllowed），
/// 在途的播放预载最多 2 个视频、量小，完成即止。
@MainActor
final class HomeFeedPreloadMemoryWarningPause {
    static let shared = HomeFeedPreloadMemoryWarningPause()

    private var pausedUntil: Date?

    private init() {}

    /// 内存警告后暂停预取一段时间（默认 30 秒）。重复警告重新计时。
    func pause(duration: TimeInterval = 30) {
        pausedUntil = Date().addingTimeInterval(duration)
    }

    /// 当前是否处于暂停期。
    var isPaused: Bool {
        guard let pausedUntil else { return false }
        return Date() < pausedUntil
    }
}
