import SwiftUI

struct BiliPlayerSurfaceOverlayLayer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var networkUnavailable = false
    let state: BiliPlayerSurfaceChromeState
    @ObservedObject var speedBoostModel: PlayerSpeedBoostModel
    @ObservedObject var seekPreviewModel: PlayerSeekPreviewModel
    /// 实时网速（左上角常驻显示）。视频详情页传 viewModel 的模型；其它入口用默认
    /// 空模型（speedText 为 nil，不显示）。直接观察模型，每秒刷新，不依赖父 view 重绘。
    @ObservedObject var networkSpeedModel: PlayerNetworkSpeedModel = PlayerNetworkSpeedModel()

    var body: some View {
        ZStack {
            if let surfaceOverlay = state.surfaceOverlay {
                surfaceOverlay
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(1)
            }

            if state.showsPlayerLoadingChrome {
                PlayerStartupLoadingChrome(isBuffering: state.isBuffering)
                    .padding(state.presentation == .embedded ? 12 : 16)
                    .zIndex(2)
            }

            if let errorMessage = state.errorMessage {
                PlayerPlaybackErrorChrome(message: errorMessage)
                    .padding(state.presentation == .embedded ? 10 : 16)
                    .zIndex(3)
            }

            if state.showsSeekSnapshot {
                PlayerRotationTransitionSnapshotView(
                    snapshot: state.seekSnapshot,
                    fallbackCoverURL: nil,
                    constrainsToVideoAspect: false
                )
                .background(Color.black)
                .opacity(state.seekSnapshotDisplayOpacity)
                .zIndex(5)
            }

            if state.showsAppBackgroundRecoverySnapshot {
                PlayerRotationTransitionSnapshotView(
                    snapshot: state.appBackgroundRecoverySnapshot,
                    fallbackCoverURL: nil,
                    constrainsToVideoAspect: state.constrainsRotationSnapshotToVideoAspect
                )
                .background(Color.black)
                .opacity(state.appBackgroundRecoverySnapshotOpacity)
                .zIndex(6)
            }

            if state.showsRotationSnapshot {
                PlayerRotationTransitionSnapshotView(
                    snapshot: state.rotationSnapshot,
                    fallbackCoverURL: state.rotationFallbackCoverURL,
                    constrainsToVideoAspect: state.constrainsRotationSnapshotToVideoAspect
                )
                .background(Color.black)
                .opacity(state.rotationSnapshotOpacity)
                .zIndex(7)
            }

            let topAccessoryPadding = max(0, state.contentInsets.top) + (state.presentation == .embedded ? 10 : 16)
            if state.showsInlineLoadingProgress, !state.isUserSeeking, !networkUnavailable {
                PlayerInlineLoadingIndicator(message: "正在缓冲")
                .padding(.top, topAccessoryPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(6)
            }

            if speedBoostModel.isIndicatorVisible {
                PlayerSpeedBoostIndicator(
                    phase: speedBoostModel.phase,
                    displayedRate: speedBoostModel.displayedRate
                )
                    .padding(.top, topAccessoryPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(6)
            }

            // 实时网速：常驻左上角，控件隐藏时也不消失（与“正在缓冲”指示不同，
            // 它是常驻层，allowsHitTesting(false) 不挡手势）。
            if let speedText = networkSpeedModel.speedText {
                Label(speedText, systemImage: "arrow.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.45), in: Capsule())
                    .padding(.top, topAccessoryPadding)
                    .padding(.leading, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
                    .zIndex(6)
            }

            if let presentation = seekPreviewModel.presentation {
                PlayerSeekPreviewOverlay(presentation: presentation)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .onAppear { updateNetworkStatus() }
        .onReceive(NotificationCenter.default.publisher(for: .biliPlaybackConnectivityDidChange)) { _ in
            updateNetworkStatus()
        }
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
            }
        }
    }
    private func updateNetworkStatus() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-player-offline") {
            networkUnavailable = true
            return
        }
        #endif
        networkUnavailable = NetworkPathSnapshot.shared.networkUnavailable == true
    }
}

private extension BiliPlayerSurfaceChromeState {
    var showsSeekSnapshot: Bool {
        seekSnapshot != nil && (isUserSeeking || seekSnapshotOpacity > 0)
    }

    var seekSnapshotDisplayOpacity: Double {
        isUserSeeking ? 1 : seekSnapshotOpacity
    }

    var showsRotationSnapshot: Bool {
        rotationSnapshotOpacity > 0
            && rotationSnapshot != nil
    }

    var showsAppBackgroundRecoverySnapshot: Bool {
        appBackgroundRecoverySnapshotOpacity > 0
            && appBackgroundRecoverySnapshot != nil
    }
}

nonisolated enum PlayerOfflineNotice {
    static func message(isBuffering: Bool) -> String {
        isBuffering ? "网络已断开，等待网络恢复" : "网络已断开"
    }
}

struct PlayerOfflineNoticeOverlay: View {
    let isBuffering: Bool
    let bottomPadding: CGFloat
    @State private var networkUnavailable = false

    var body: some View {
        ZStack {
            if networkUnavailable {
                Label(PlayerOfflineNotice.message(isBuffering: isBuffering), systemImage: "wifi.slash")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .biliPlayerClearGlass(interactive: false, in: Capsule())
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("player.network.disconnected")
                    .padding(.horizontal, 12)
                    .padding(.bottom, bottomPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .onAppear { updateNetworkStatus() }
        .onReceive(NotificationCenter.default.publisher(for: .biliPlaybackConnectivityDidChange)) { _ in
            updateNetworkStatus()
        }
    }

    private func updateNetworkStatus() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-player-offline") {
            networkUnavailable = true
            return
        }
        #endif
        networkUnavailable = NetworkPathSnapshot.shared.networkUnavailable == true
    }
}

struct PlayerProgressBoundsPreferenceKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

extension View {
    func playerOfflineNotice(
        isBuffering: Bool,
        isPresented: Bool = true,
        bottomInset: CGFloat = 0
    ) -> some View {
        overlayPreferenceValue(PlayerProgressBoundsPreferenceKey.self) { progressBounds in
            if isPresented {
                GeometryReader { proxy in
                    // Track the actual slider, including fullscreen safe-area spacing.
                    // Hidden controls fall back above the persistent bottom progress strip.
                    let bottomPadding = progressBounds.map {
                        max(8, proxy.size.height - proxy[$0].minY + 8)
                    } ?? (bottomInset + VideoDetailPinnedProgressBar.height + 8)
                    PlayerOfflineNoticeOverlay(
                        isBuffering: isBuffering,
                        bottomPadding: bottomPadding
                    )
                }
                .allowsHitTesting(false)
            }
        }
    }
}
