import SwiftUI
import UIKit

struct VideoDetailExpandedDescriptionText: View {
    let descriptionText: String

    var body: some View {
        // 第 9 轮简介页紧凑化：展开的简介正文字号由 caption1（12pt）降为 caption2（11pt）。
        // 注意：简介内容本身不是重复的 UP 名——本例视频的 desc 字段就是 "天天相见厨房"，
        // 展开后才显示，折叠时不渲染；保留，只改小。
        BiliLinkedText(
            descriptionText,
            font: UIFont.preferredFont(forTextStyle: .caption2),
            textColor: .secondary
        )
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .commentCopyContextMenu(text: descriptionText, title: "复制简介")
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
