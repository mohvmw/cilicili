import SwiftUI
import UIKit

struct VideoDetailInfoTitleText: View {
    let text: String
    let isExpanded: Bool

    var body: some View {
        // 第 9 轮简介页紧凑化：标题由 .videoDetailTitle（17pt）改用 .compactVideoTitle（14pt semibold）。
        // 只改简介页标题这一个调用点；不改 PlaybackDetailTitleText 的默认 role，
        // 直播间标题（LiveRoomMinimalDetailHeader 共用该组件）保持原样。
        PlaybackDetailTitleText(
            text: text,
            lineLimit: isExpanded ? nil : 1,
            typographyRole: .compactVideoTitle
        )
    }
}
