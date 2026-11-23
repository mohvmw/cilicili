import SwiftUI

struct InitialVideoDetailControls: View {
    let titleText: String
    let contentWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VideoDetailInfoLoadingPlaceholder(titleText: titleText)
            InitialVideoDetailActionStrip(contentWidth: contentWidth)
        }
        .frame(width: contentWidth, alignment: .leading)
        .allowsHitTesting(false)
    }
}

private struct InitialVideoDetailActionStrip: View {
    let contentWidth: CGFloat

    var body: some View {
        // 第 10 轮去掉头像占位圆：真实操作行第 9 轮已去头像列，只剩 4 个按钮，
        // 骨架再渲染头像圆会在视频打开瞬间闪一下、随后消失；现只留 4 个图标占位，
        // 与真实行一一对齐。图标占位圆随 Metrics 收小（28→24）。
        HStack(spacing: layout.actionSpacing) {
            ForEach(0..<4, id: \.self) { _ in
                iconPlaceholder
                    .frame(width: layout.columnWidth, height: layout.rowHeight)
            }
        }
        .frame(
            width: contentWidth,
            height: layout.rowHeight,
            alignment: .leading
        )
        .accessibilityHidden(true)
    }

    private var iconPlaceholder: some View {
        Circle()
            .fill(VideoDetailTheme.secondarySurface.opacity(VideoDetailSkeletonStyle.actionStripFillOpacity))
            .frame(
                width: layout.actionLabelSide,
                height: layout.actionLabelSide
            )
    }

    private var layout: VideoDetailActionStripLayout {
        VideoDetailActionStripLayout(contentWidth: contentWidth)
    }
}
