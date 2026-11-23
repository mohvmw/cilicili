import SwiftUI

struct VideoDetailActionStrip: View, Equatable {
    enum Metrics {
        // 第 9 轮简介页紧凑化：行高 44→40、按钮圆 32→28、图标 17→15。
        // avatarImageSide 44→40：真实操作行已无头像列，该值现仅供加载骨架占位
        //（InitialVideoDetailControls）使用，随行高一并收紧；avatarPixelSize 不变，
        // UP 行 32pt 头像仍用它（3x 屏只需 96px）。
        static let rowHeight: CGFloat = 40
        static let actionLabelSide: CGFloat = 28
        static let avatarImageSide: CGFloat = 40
        static let iconSize: CGFloat = 15
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
