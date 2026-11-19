import SwiftUI

/// 简介页顶部的 UP 行（对齐原版顺序：UP 行 → 标题 → 数据行 → 操作行）。
/// 头像 + UP 名点开进个人空间；关注 pill 复用操作行的关注行为。
struct VideoDetailUploaderRow: View {
    @Environment(\.appThemeTintColor) private var appTintColor

    @ObservedObject var store: VideoDetailDescriptionRenderStore
    let onFollow: () -> Void

    var body: some View {
        if let owner = store.owner {
            HStack(spacing: 10) {
                VideoOwnerRouteLink(owner: owner) {
                    PlaybackDetailOwnerAvatarImage(
                        urlString: owner.face?.normalizedBiliURL(),
                        side: 40,
                        pixelSize: VideoDetailActionStrip.Metrics.avatarPixelSize,
                        showsShadow: false,
                        showsBorder: false
                    )
                }
                .accessibilityLabel("\(owner.name)，查看个人空间")

                VStack(alignment: .leading, spacing: 2) {
                    VideoOwnerRouteLink(owner: owner) {
                        Text(owner.name)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(appTintColor)
                            .lineLimit(1)
                    }

                    // 粉丝数来自 UP 资料接口；没拿到（"粉丝 -"）时不显示，不编造数据。
                    if store.fanCountText != "粉丝 -" {
                        Text(store.fanCountText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button(action: onFollow) {
                    Label(
                        store.isFollowing ? "已关注" : "关注",
                        systemImage: store.isFollowing ? "checkmark" : "plus"
                    )
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(store.isFollowing
                                  ? Color.secondary.opacity(0.12)
                                  : appTintColor.opacity(0.12))
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(store.isFollowing ? .secondary : appTintColor)
                .disabled(store.isMutatingInteraction)
                .accessibilityLabel(store.isFollowing ? "已关注，点击取消关注" : "关注这位 UP 主")
                .accessibilityIdentifier("video.detail.uploaderRow.follow")
            }
        }
    }
}
