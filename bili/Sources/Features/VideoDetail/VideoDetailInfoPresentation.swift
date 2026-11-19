import Foundation

struct VideoDetailInfoPresentation {
    let titleText: String
    let descriptionText: String
    let hasDescriptionContent: Bool
    let metadataText: String

    init(store: VideoDetailDescriptionRenderStore) {
        titleText = Self.titleText(from: store)
        descriptionText = store.descriptionText

        let descriptionPreview = Self.collapsedDescriptionPreview(descriptionText)
        hasDescriptionContent = descriptionPreview != nil
        metadataText = Self.metadataText(store: store)
    }

    private static func titleText(from store: VideoDetailDescriptionRenderStore) -> String {
        if !store.titleText.isEmpty {
            return store.titleText
        }
        return "视频详情"
    }

    private static func metadataText(
        store: VideoDetailDescriptionRenderStore
    ) -> String {
        // 数据行：只放播放数 / 弹幕数 / 发布日期。UP 名已移到上方的 UP 行，
        // 简介预览不再跟在数据行后面（折叠时只显示数据行，简介靠展开箭头查看）。
        var parts = [String]()

        if store.viewCountText != "-" {
            parts.append("\(store.viewCountText)观看")
        }

        if store.danmakuCountText != "-" {
            parts.append("\(store.danmakuCountText)弹幕")
        }

        if store.publishDateText != "-" {
            parts.append(store.publishDateText)
        }

        return parts.isEmpty ? "视频详情" : parts.joined(separator: "  ")
    }

    private static func collapsedDescriptionPreview(_ text: String) -> String? {
        let trimmed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "这个视频暂时没有简介。" else { return nil }
        return trimmed
    }
}
