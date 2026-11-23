import SwiftUI

struct VideoDetailActionStrip: View, Equatable {
    enum Metrics {
        // 第 10 轮简介页再紧凑：行高 40→36、按钮圆 28→24、图标 15→13；
        // 图标与圆环的留白比例与第 9 轮一致（图标比圆小 11pt），不会溢出圆。
        // avatarImageSide 仅供单元测试引用（见 VideoDetailActionStripLayout 的注释），
        // 真实操作行与加载骨架均已无头像列；avatarPixelSize 不变，
        // UP 行 32pt 头像仍用它（3x 屏只需 96px）。
        static let rowHeight: CGFloat = 36
        static let actionLabelSide: CGFloat = 24
        static let avatarImageSide: CGFloat = 40
        static let iconSize: CGFloat = 13
        static let avatarPixelSize = 112
    }

    let model: VideoDetailActionStripModel
    // 关注入口已在 UP 行；onFollow 不再向下传给 ButtonRow（头像菜单已随头像列去掉）。
    // 保留本参数只因 UI 测试夹具 UITestVideoOwnerMenuFixtureView 仍按此签名构造，
    // 待夹具更新后可删。
    let onFollow: () -> Void
    let onLike: () -> Void
    let onCoin: () -> Void
    let onFavorite: () -> Void
    @Environment(\.videoDetailActionButtonStyle) private var actionButtonStyle

    static func == (lhs: VideoDetailActionStrip, rhs: VideoDetailActionStrip) -> Bool {
        lhs.model == rhs.model
    }

    var body: some View {
        let usesPlainStyle = actionButtonStyle.usesPlainStyle
        let layout = VideoDetailActionStripLayout(contentWidth: model.contentWidth)

        Group {
            if usesPlainStyle {
                VideoDetailActionStripButtonRow(
                    model: model,
                    layout: layout,
                    onLike: onLike,
                    onCoin: onCoin,
                    onFavorite: onFavorite,
                    usesPlainStyle: true
                )
            } else {
                GlassEffectContainer(spacing: layout.actionSpacing) {
                    VideoDetailActionStripButtonRow(
                        model: model,
                        layout: layout,
                        onLike: onLike,
                        onCoin: onCoin,
                        onFavorite: onFavorite,
                        usesPlainStyle: false
                    )
                }
            }
        }
        .frame(width: model.contentWidth, height: layout.rowHeight, alignment: .center)
    }
}
