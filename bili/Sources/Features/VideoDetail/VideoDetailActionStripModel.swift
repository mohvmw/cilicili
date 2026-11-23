import SwiftUI

struct VideoDetailActionStripModel: Equatable {
    // 第 9 轮简介页紧凑化：操作行头像列已去掉，owner / isFollowing / isMutatingFollow
    // 不再参与渲染（关注入口在 UP 行）。保留这三个字段：Equatable 对比仍以整个 model
    // 为准，且 UI 测试夹具 UITestVideoOwnerMenuFixtureView 仍按此签名构造 model；
    // 待夹具更新后可随 ownerForDisplay 一并删。
    let owner: VideoOwner?
    var aid: Int? = nil
    let canFavorite: Bool
    let shareURL: URL?
    let shareSubject: String
    let shareMessage: String
    let contentWidth: CGFloat
    let isFollowing: Bool
    let isLiked: Bool
    let isCoined: Bool
    let isFavorited: Bool
    let coinCount: Int
    let isMutatingLike: Bool
    let isMutatingCoin: Bool
    let isMutatingFavorite: Bool
    let isMutatingFollow: Bool
}
