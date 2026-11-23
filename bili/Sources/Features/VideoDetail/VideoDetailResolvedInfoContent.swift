import SwiftUI

struct VideoDetailResolvedInfoContent: View {
    @ObservedObject var store: VideoDetailDescriptionRenderStore
    @Binding var isExpanded: Bool

    private var presentation: VideoDetailInfoPresentation {
        VideoDetailInfoPresentation(store: store)
    }

    var body: some View {
        // 第 9 轮简介页紧凑化：标题 / 数据行 / 展开简介之间的间距 6→4。
        VStack(alignment: .leading, spacing: 4) {
            titleRow
                .commentCopyContextMenu(text: store.titleText, title: "复制标题")

            VideoDetailInfoMetadataRow(
                metadataText: presentation.metadataText,
                descriptionCopyText: presentation.hasDescriptionContent && !isExpanded ? presentation.descriptionText : nil
            )

            if isExpanded && presentation.hasDescriptionContent {
                VideoDetailExpandedDescriptionText(descriptionText: presentation.descriptionText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 第 10 轮 A：这个 .animation 的作用域就是上面这个 VStack（标题行 + 数据行 +
        // 展开简介），它是简介块内部唯一的动画驱动。UP 行是 VideoDetailSummaryCard
        // 里与本块平级的兄弟视图，不在这个 VStack 内，所以本修饰符碰不到它——
        // 之前怀疑的“外层动画连 UP 行一起做”经核查不成立，真正的泄漏点在下面的
        // toggleExpansion（事务级 withAnimation），见该处注释。
        .animation(.snappy(duration: 0.22), value: isExpanded)
    }

    @ViewBuilder
    private var titleRow: some View {
        if presentation.hasDescriptionContent || presentation.titleText.contains(where: \.isNewline) {
            expandableTitle
        } else {
            ViewThatFits(in: .horizontal) {
                VideoDetailInfoTitleText(text: presentation.titleText, isExpanded: false)
                    .fixedSize(horizontal: true, vertical: false)

                expandableTitle
            }
        }
    }

    private var expandableTitle: some View {
        HStack(alignment: .top, spacing: 6) {
            VideoDetailInfoTitleText(text: presentation.titleText, isExpanded: isExpanded)

            Button(action: toggleExpansion) {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(isExpanded ? "收起视频详情" : "展开视频详情")
        }
    }

    private func toggleExpansion() {
        // 第 10 轮 A：去掉 withAnimation。withAnimation 会把 .snappy 弹簧写进整条事务，
        // 于是同一次提交里其它所有变化也跟着做动画——简介块下方整块内容（操作行 /
        // 合集 / 相关推荐）上滑约 130px，以及恰好赶在同一 runloop 提交的其它刷新
        // （store 发布、父视图重算等），都会被弹簧带上，视觉上就是简介页顶部闪一下。
        // 只保留上面 VStack 上的 .animation(..., value: isExpanded)：它是作用域内的
        // 唯一驱动，标题行数变化和展开简介的显隐照样平滑，兄弟视图的跟随滑动也照样
        // 由布局插值完成（SwiftUI 会对动画视图的高度变化做布局跟随），只是不再有
        // 事务级动画泄漏到 UP 行和其它无关视图。
        isExpanded.toggle()
    }
}
