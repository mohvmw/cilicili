import os
import SwiftUI

private let summaryCardLogger = Logger(subsystem: "cc.bili", category: "VideoDetailSummary")

struct VideoDetailSummaryCard: View {
    let viewModel: VideoDetailViewModel
    let contentWidth: CGFloat
    let showsNetworkDiagnosticsButton: Bool
    let showsVideoInfo: Bool
    let onShowNetworkDiagnostics: () -> Void
    let onShowCoinPicker: () -> Void
    let renderPack: VideoDetailSummaryCardRenderPack
    @ObservedObject private var descriptionStore: VideoDetailDescriptionRenderStore

    init(
        viewModel: VideoDetailViewModel,
        contentWidth: CGFloat,
        showsNetworkDiagnosticsButton: Bool,
        showsVideoInfo: Bool = true,
        onShowNetworkDiagnostics: @escaping () -> Void,
        onShowFavoriteFolders: @escaping () -> Void,
        onShowCoinPicker: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.contentWidth = contentWidth
        self.showsNetworkDiagnosticsButton = showsNetworkDiagnosticsButton
        self.showsVideoInfo = showsVideoInfo
        self.onShowNetworkDiagnostics = onShowNetworkDiagnostics
        self.onShowCoinPicker = onShowCoinPicker
        let pack = VideoDetailSummaryCardRenderPack(
            viewModel: viewModel,
            showFavoriteFolders: onShowFavoriteFolders
        )
        renderPack = pack
        descriptionStore = pack.descriptionStore
    }

    var body: some View {
        // 第 9 轮简介页紧凑化：UP 行 / 信息块 / 操作行之间的间距 12→8。
        VStack(alignment: .leading, spacing: 8) {
            // UP 行不跟 showsVideoInfo 走：PGC 分集下标题由分集区自己出，
            // 但只要有 UP 数据就该显示 UP 行；没 UP 数据时行内 if let 本身不渲染。
            // （第 1 步曾把它和标题绑在同一个门里，showsVideoInfo 为 false 时
            // UP 行被一并藏掉，简介页看起来和改前一模一样。）
            VideoDetailUploaderRow(
                store: renderPack.descriptionStore,
                onFollow: renderPack.actions.follow
            )
            // 第 10 轮 A：UP 行动画隔离（只影响简介页顶部这一行，不动关注行为和布局）。
            // .id：以 UP 的 mid 做稳定 identity。UP 不变时行 identity 不变，头像的
            // CachedRemoteImage（@StateObject loader + retained 显示缓存）不会因父视图
            // 重算而重建、重载；换 UP（mid 变）或首次拿到 UP 数据时才重置一次，这正是
            // 该换头像的时刻。不能用 .equatable() 代替：onFollow 是每次 init 新建的闭包，
            // 无法参与相等比较。
            // .transaction：把到达本行的任何事务动画清掉。即使上层某处再出现事务级动画，
            // UP 行（头像 / 名字 / 粉丝数 / 关注 pill）也只会瞬时更新，不做插值、不闪。
            // 关注 pill 本身没有声明动画，点关注时状态切换本来就是瞬时的，此处无行为变化。
            .id(descriptionStore.owner?.mid ?? 0)
            .transaction { transaction in
                transaction.animation = nil
            }

            if showsVideoInfo {
                // 对齐原版顺序：UP 行 → 标题 → 数据行 → 操作行。
                VideoDetailInfoBlock(
                    store: renderPack.descriptionStore
                )
            }

            VideoDetailActionStripContainer(
                descriptionStore: renderPack.descriptionStore,
                store: renderPack.interactionStore,
                contentWidth: contentWidth,
                aid: viewModel.detail.aid,
                onFollow: renderPack.actions.follow,
                onLike: renderPack.actions.like,
                onCoin: showCoinPicker,
                onFavorite: renderPack.actions.favorite
            )

            if showsNetworkDiagnosticsButton {
                VideoDetailNetworkDiagnosticsButton(action: onShowNetworkDiagnostics)
            }

            VideoDetailInteractionNotice(store: renderPack.interactionStore)
            VideoDetailPlayURLNotice(
                placeholderStore: renderPack.placeholderStore,
                retry: renderPack.actions.retryPlayURL
            )
        }
        .frame(width: contentWidth, alignment: .leading)
        .onAppear {
            logUploaderRowState()
        }
        .onChange(of: descriptionStore.owner) { _, _ in
            logUploaderRowState()
        }
    }

    /// 诊断日志：UP 行显隐的唯一依据就是 store.owner 是否有值。
    /// 若真机仍报“没有效果”，凭这行日志可区分是没 UP 数据（hidden）
    /// 还是新包没装上（根本没这行日志）。
    private func logUploaderRowState() {
        if let owner = descriptionStore.owner {
            summaryCardLogger.debug("uploader row shown: \(owner.name, privacy: .public) (showsVideoInfo: \(showsVideoInfo))")
        } else {
            summaryCardLogger.debug("uploader row hidden: no owner (showsVideoInfo: \(showsVideoInfo))")
        }
    }

    private func showCoinPicker() {
        Haptics.medium()
        onShowCoinPicker()
    }
}
