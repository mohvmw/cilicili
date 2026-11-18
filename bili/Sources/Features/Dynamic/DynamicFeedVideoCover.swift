import SwiftUI

enum DynamicFeedMediaMetrics {
    // 动态页视频封面与多图网格外角：与首页一致，改直角（原 20）。
    static let coverCornerRadius: CGFloat = 0
}

struct DynamicFeedVideoCover: View {
    @Environment(\.showsVideoCoverDurationBadges) private var showsVideoCoverDurationBadges
    let video: VideoItem
    let display: VideoCardDisplayModel
    @State private var coverLoadedState = VideoCoverLoadedState()

    var body: some View {
        FixedAspectPreview(aspectRatio: 16 / 9) {
            ZStack {
                Color.clear

                AdaptiveVideoCoverImage(
                    display: display,
                    style: .maxSide,
                    onPhaseChange: { phase in
                        coverLoadedState.update(phase: phase, identity: display.coverLoadIdentity)
                    }
                )

                if coverLoadedState.isLoaded(identity: display.coverLoadIdentity) {
                    VideoCoverBottomScrim()

                    DynamicVideoPlayBadge(size: 34, iconSize: 14)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

                    if showsVideoCoverDurationBadges, video.duration != nil {
                        VideoCoverDurationBadge(BiliFormatters.duration(video.duration))
                            .padding(12)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                }
            }
        }
        // 120Hz：封面阴影要离屏渲染，首次渲染贵；与首页一致去掉阴影，只留描边。
        .videoCoverSurface(cornerRadius: DynamicFeedMediaMetrics.coverCornerRadius)
    }
}
