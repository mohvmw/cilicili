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
