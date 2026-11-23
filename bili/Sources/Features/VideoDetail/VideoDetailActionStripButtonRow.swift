import SwiftUI

struct VideoDetailActionStripButtonRow: View {
    @EnvironmentObject private var dependencies: AppDependencies
    @Environment(\.appThemeTintColor) private var appTintColor

    let model: VideoDetailActionStripModel
    let layout: VideoDetailActionStripLayout
    let onLike: () -> Void
    let onCoin: () -> Void
    let onFavorite: () -> Void
    let usesPlainStyle: Bool

    var body: some View {
        // 第 9 轮简介页紧凑化：去掉操作行最左边的头像列（原来是 model.owner 时渲染
        // VideoDetailActionStripOwnerMenu、无 owner 时渲染占位头像）。
        // UP 行已有头像 + 关注入口，头像列纯属重复；去掉后行内只剩点赞 / 投币 / 收藏 / •••，
        // 从行首开始排，不留空位。列宽改由 4 列重算，见 VideoDetailActionStripLayout。
        HStack(spacing: layout.actionSpacing) {
            VideoDetailActionStripIconButton(
                accessibilityTitle: "点赞",
                systemImage: "hand.thumbsup",
                foregroundStyle: iconForegroundStyle(isSelected: model.isLiked),
                isDisabled: model.isMutatingLike,
                action: onLike,
                usesPlainStyle: usesPlainStyle
            )
            .frame(width: layout.columnWidth, height: layout.rowHeight)
            .accessibilityIdentifier("video.detail.like")

            VideoDetailActionStripIconButton(
                accessibilityTitle: model.isCoined ? "已投币" : "投币",
                systemImage: model.isCoined ? "bitcoinsign.circle.fill" : "bitcoinsign.circle",
                foregroundStyle: iconForegroundStyle(isSelected: model.isCoined),
                isDisabled: model.isMutatingCoin,
                action: onCoin,
                usesPlainStyle: usesPlainStyle,
                dimsWhenDisabled: true,
                blocksTouches: model.coinCount >= 2
            )
            .frame(width: layout.columnWidth, height: layout.rowHeight)
            .accessibilityIdentifier("video.detail.coin")

            VideoDetailActionStripIconButton(
                accessibilityTitle: model.isFavorited ? "已收藏" : "收藏",
                systemImage: "star",
                foregroundStyle: iconForegroundStyle(isSelected: model.isFavorited),
                isDisabled: model.isMutatingFavorite || !model.canFavorite,
                action: onFavorite,
                usesPlainStyle: usesPlainStyle
            )
            .frame(width: layout.columnWidth, height: layout.rowHeight)
            .accessibilityIdentifier("video.detail.favorite")

            VideoDetailMoreMenu(
                api: dependencies.api, aid: model.aid,
                shareURL: model.shareURL, shareSubject: model.shareSubject, shareMessage: model.shareMessage,
                usesPlainStyle: usesPlainStyle
            )
            .frame(width: layout.columnWidth, height: layout.rowHeight)
        }
        .frame(width: layout.contentWidth, alignment: .leading)
    }

    private func iconForegroundStyle(isSelected: Bool) -> Color {
        guard usesPlainStyle else { return isSelected ? appTintColor : .primary }
        return isSelected ? appTintColor : .secondary
    }
}
