import SwiftUI

/// 第 17 轮：拖动期间禁止点按的共享状态（引用类型）。
///
/// 机制：简介/评论切换时页面跟手滑动（dragOffset = translation.width），手指
/// 全程停在同一张卡片/评论行上，松手时 Button 照常触发——第 15 轮的
/// allowsHitTesting(false) 只影响新触点的 hit-testing，拦不住已经按下去的
/// in-flight Button（hit-testing 只在触点落下时做一次，之后改 allowsHitTesting
/// 不会取消已在进行的按压；简介/评论的滚动视图又是竖向的，横滑不会触发它
/// 取消点按）。所以点按必须在触发时拦：各点按处理在 action 里读这个标志，
/// 拖动期间直接跳过。
///
/// 用引用类型而不用 Bool 环境值：简介页内容在 UIHostingController 里、评论行
/// 在 UITableView cell 的 UIHostingController 里，环境值只在 rootView 重建时
/// 才更新；引用对象原地变值，点按处理在触发时读到的永远是最新值，不需要视图重建。
/// tab view 用 @StateObject 持有唯一实例；点按处理只在触发时读 isSuppressed，
/// 不订阅、不触发重渲染。
@MainActor
final class VideoDetailTapSuppression: ObservableObject {
    @Published var isSuppressed = false
}

private struct VideoDetailTapSuppressionKey: EnvironmentKey {
    static let defaultValue: VideoDetailTapSuppression? = nil
}

extension EnvironmentValues {
    /// 拖动期间禁止点按的共享状态（nil = 不抑制，默认行为不变）。
    /// 由 VideoDetailNativeContentTabView 提供；VideoRouteLink 与评论行
    /// 的点按处理在触发前读它。
    var videoDetailTapSuppression: VideoDetailTapSuppression? {
        get { self[VideoDetailTapSuppressionKey.self] }
        set { self[VideoDetailTapSuppressionKey.self] = newValue }
    }
}
