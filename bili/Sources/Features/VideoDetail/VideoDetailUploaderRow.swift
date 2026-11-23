import SwiftUI

/// 简介页顶部的 UP 行（对齐原版顺序：UP 行 → 标题 → 数据行 → 操作行）。
/// 头像 + UP 名点开进个人空间；关注 pill 复用操作行的关注行为。
/// 第 10 轮 A：本行内部不挂任何 .animation 修饰符；防闪的隔离（稳定 identity +
/// 事务动画清零）放在 VideoDetailSummaryCard 的调用处。头像本身也不会因重渲染而闪：
/// PlaybackDetailOwnerAvatarImage → CachedRemoteImage 用 @StateObject 持有 loader、
/// retained 显示缓存、animatesAppearance = false，只要行 identity 稳定就不会重载占位图。
struct VideoDetailUploaderRow: View {
    @Environment(\.appThemeTintColor) private var appTintColor
    /// 第 18 轮：拖动期间禁止点按的共享状态（简介页内容在 UIHostingController 里，
    /// 第 17 轮已在 scrollContent 显式注入环境，UP 行在 summary 卡片里、能读到；
    /// 其他地方为 nil = 不抑制）。
    @Environment(\.videoDetailTapSuppression) private var tapSuppression

    @ObservedObject var store: VideoDetailDescriptionRenderStore
    let onFollow: () -> Void

    var body: some View {
        if let owner = store.owner {
            // 第 9 轮简介页紧凑化：UP 行整体改小一号（头像 40→32、名字/关注 pill 字号各降一档），
            // 只影响简介页顶部的 UP 行，不动关注行为本身。
            HStack(spacing: 8) {
                VideoOwnerRouteLink(owner: owner) {
                    PlaybackDetailOwnerAvatarImage(
                        urlString: owner.face?.normalizedBiliURL(),
                        side: 32,
                        // pixelSize 保持 112：32pt 头像在 3x 屏上只需 96px，112 仍有余量，不必跟着改小。
                        pixelSize: VideoDetailActionStrip.Metrics.avatarPixelSize,
                        showsShadow: false,
                        showsBorder: false
                    )
                }
                .accessibilityLabel("\(owner.name)，查看个人空间")

                VStack(alignment: .leading, spacing: 1) {
                    VideoOwnerRouteLink(owner: owner) {
                        Text(owner.name)
                            .font(.footnote)
                            .fontWeight(.semibold)
                            .foregroundStyle(appTintColor)
                            .lineLimit(1)
                    }

                    // 粉丝数来自 UP 资料接口；没拿到（"粉丝 -"）时不显示，不编造数据。
                    if store.fanCountText != "粉丝 -" {
                        Text(store.fanCountText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Button(action: guardedFollow) {
                    Label(
                        store.isFollowing ? "已关注" : "关注",
                        systemImage: store.isFollowing ? "checkmark" : "plus"
                    )
                    .font(.footnote)
                    .fontWeight(.medium)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
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

    /// 第 18 轮：拖动期间禁止点按。Button 在松手、手指仍在其 bounds 内时触发；
    /// 跟手滑动时 UP 行跟着手指走，松手时仍在 Button 内，allowsHitTesting
    /// 拦不住 in-flight 按压，所以在触发时拦。环境默认 nil = 不抑制。
    private func guardedFollow() {
        guard tapSuppression?.isSuppressed != true else { return }
        onFollow()
    }
}
