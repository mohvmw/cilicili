import SwiftUI

/// Button style affects appearance only; both styles share the same compact action geometry.
struct VideoDetailActionStripLayout {
    // 第 9 轮简介页紧凑化：操作行去掉头像列后只剩点赞 / 投币 / 收藏 / ••• 共 4 列，
    // 列宽与间距按 4 列重算（原来按头像 + 4 按钮共 5 列）。
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

    // 以下三项仅供加载骨架占位（InitialVideoDetailControls.swift）使用，
    // 真实操作行已无头像列；该文件不在本轮改动范围，待它去掉头像占位后可随之删除。
    // 保留它们可保证骨架文件继续编译；数值与新行高对齐，不影响真实行布局。
    private static let preferredAvatarGap: CGFloat = 20
    var avatarActionSpacing: CGFloat { compactSpacingScale * Self.preferredAvatarGap }
    var avatarImageSide: CGFloat { VideoDetailActionStrip.Metrics.avatarImageSide }
    var avatarColumnWidth: CGFloat { columnWidth }
}
