import SwiftUI

/// Button style affects appearance only; both styles share the same compact action geometry.
struct VideoDetailActionStripLayout {
    // 第 9 轮简介页紧凑化：操作行去掉头像列后只剩点赞 / 投币 / 收藏 / ••• 共 4 列，
    // 列宽与间距按 4 列重算（原来按头像 + 4 按钮共 5 列）。
    // 第 10 轮再收一档：行高 40→36（见 Metrics），列宽随行高自动收小
    //（columnWidth = min(rowHeight, contentWidth / 4)），间距按新列宽重算，无需另改数值。
    private static let preferredActionGap: CGFloat = 12

    let contentWidth: CGFloat

    var actionSpacing: CGFloat { compactSpacingScale * Self.preferredActionGap }
    var contentGroupWidth: CGFloat {
        columnWidth * 4 + actionSpacing * 3
    }
    private var compactSpacingScale: CGFloat {
        let preferredSpacing = Self.preferredActionGap * 3
        return min(max(contentWidth - columnWidth * 4, 0) / preferredSpacing, 1)
    }
    var rowHeight: CGFloat { VideoDetailActionStrip.Metrics.rowHeight }
    var actionLabelSide: CGFloat { VideoDetailActionStrip.Metrics.actionLabelSide }
    var columnWidth: CGFloat { min(rowHeight, max(contentWidth / 4, 1)) }

    // 以下三项自第 10 轮起不再被任何生产代码引用：真实操作行第 9 轮已去头像列，
    // 加载骨架（InitialVideoDetailControls.swift）本轮也去掉了头像占位。
    // 保留只因 biliTests 仍引用它们（DynamicInteractionAndDetailTests 的
    // testVideoDetailInlineActionsUseExpandedTouchTarget、VideoDetailOwnerMenuTests 的
    // testActionStripUsesCompactLeftAlignedGeometryWithoutOverflow）；
    // 待测试随之更新后可连同 Metrics.avatarImageSide 一并删除。
    // 数值沿用第 9 轮，不影响真实行布局。
    private static let preferredAvatarGap: CGFloat = 20
    var avatarActionSpacing: CGFloat { compactSpacingScale * Self.preferredAvatarGap }
    var avatarImageSide: CGFloat { VideoDetailActionStrip.Metrics.avatarImageSide }
    var avatarColumnWidth: CGFloat { columnWidth }
}
