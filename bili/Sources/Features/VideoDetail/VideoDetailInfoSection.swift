import SwiftUI

struct VideoDetailInfoBlock: View {
    @ObservedObject var store: VideoDetailDescriptionRenderStore
    // 第 10 轮 A：isExpanded 故意只放在本块的 @State，不进 store、不上交 SummaryCard。
    // 切换它只会让本块（标题 / 数据行 / 展开简介）重算，UP 行和操作行不会因此重渲染；
    // 动画也只由 VideoDetailResolvedInfoContent 里作用域内的 .animation(value:) 驱动。
    @State private var isExpanded = false

    var body: some View {
        Group {
            if store.hasResolvedDetailMetadata {
                VideoDetailResolvedInfoContent(
                    store: store,
                    isExpanded: $isExpanded
                )
            } else {
                VideoDetailInfoLoadingPlaceholder(titleText: store.titleText)
            }
        }
    }
}
