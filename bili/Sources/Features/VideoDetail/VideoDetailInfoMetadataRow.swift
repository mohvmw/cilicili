import SwiftUI

struct VideoDetailInfoMetadataRow: View {
    let metadataText: String
    let descriptionCopyText: String?

    var body: some View {
        // 第 9 轮简介页紧凑化：数据行字号由 .metadata（12pt）降为 .tertiaryMetadata（11pt），
        // 行高 24→20。只影响简介页数据行（本组件仅在 VideoDetailResolvedInfoContent 中使用）。
        Text(metadataText)
            .appTypography(.tertiaryMetadata, fallback: .caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(height: 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .commentCopyContextMenu(text: descriptionCopyText, title: "复制简介")
    }
}
