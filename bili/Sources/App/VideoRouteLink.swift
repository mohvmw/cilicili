import SwiftUI

private struct OpenVideoActionKey: EnvironmentKey {
    static let defaultValue: ((VideoItem) -> Void)? = nil
}

private struct OpenLiveRoomActionKey: EnvironmentKey {
    static let defaultValue: ((LiveRoom) -> Void)? = nil
}

private struct PrewarmVideoRouteActionKey: EnvironmentKey {
    static let defaultValue: ((VideoItem) -> Void)? = nil
}

private struct OpenPgcSeasonRouteActionKey: EnvironmentKey {
    static let defaultValue: ((PgcSeasonRoute) -> Void)? = nil
}

private struct OpenVideoOwnerRouteActionKey: EnvironmentKey {
    static let defaultValue: ((VideoOwner) -> Void)? = nil
}

extension EnvironmentValues {
    var openVideoAction: ((VideoItem) -> Void)? {
        get { self[OpenVideoActionKey.self] }
        set { self[OpenVideoActionKey.self] = newValue }
    }

    var openLiveRoomAction: ((LiveRoom) -> Void)? {
        get { self[OpenLiveRoomActionKey.self] }
        set { self[OpenLiveRoomActionKey.self] = newValue }
    }

    var prewarmVideoRouteAction: ((VideoItem) -> Void)? {
        get { self[PrewarmVideoRouteActionKey.self] }
        set { self[PrewarmVideoRouteActionKey.self] = newValue }
    }

    var openPgcSeasonRouteAction: ((PgcSeasonRoute) -> Void)? {
        get { self[OpenPgcSeasonRouteActionKey.self] }
        set { self[OpenPgcSeasonRouteActionKey.self] = newValue }
    }

    var openVideoOwnerRouteAction: ((VideoOwner) -> Void)? {
        get { self[OpenVideoOwnerRouteActionKey.self] }
        set { self[OpenVideoOwnerRouteActionKey.self] = newValue }
    }
}

struct VideoOwnerRouteLink<Label: View>: View {
    let owner: VideoOwner
    @ViewBuilder let label: () -> Label
    @Environment(\.openVideoOwnerRouteAction) private var openVideoOwnerRoute
    /// 第 19 轮：拖动期间禁止点按的共享状态。详情页里 openVideoOwnerRoute 由
    /// RootTabView 提供，走 Button 路径；简介页 scrollContent 与评论页 cell
    /// 里都已注入环境（第 17 轮），能读到。详情页外环境为 nil = 不抑制，
    /// 其他页面的 UP 头像/名字行为不变。NavigationLink 备用路径（action 为 nil
    /// 时）无法在触发时拦，但只在详情页外出现，那里本就不抑制。
    @Environment(\.videoDetailTapSuppression) private var tapSuppression

    var body: some View {
        if let openVideoOwnerRoute {
            Button(action: guardedOpenOwner) {
                label()
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: owner) {
                label()
            }
            .buttonStyle(.plain)
        }
    }

    /// 第 19 轮：拖动期间禁止点按。Button 在松手、手指仍在其 bounds 内时触发；
    /// 跟手滑动时 UP 行跟着手指走，松手时仍在 Button 内，allowsHitTesting
    /// 拦不住 in-flight 按压，所以在触发时拦。环境默认 nil = 不抑制。
    private func guardedOpenOwner() {
        guard tapSuppression?.isSuppressed != true else { return }
        openVideoOwnerRoute?(owner)
    }
}

struct VideoRouteLink<Label: View>: View {
    let video: VideoItem
    let onOpen: (() -> Void)?
    @ViewBuilder let label: () -> Label
    @Environment(\.openVideoAction) private var openVideo
    @Environment(\.prewarmVideoRouteAction) private var prewarmVideoRoute

    init(
        _ video: VideoItem,
        onOpen: (() -> Void)? = nil,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.video = video
        self.onOpen = onOpen
        self.label = label
    }

    var body: some View {
        if let openVideo {
            VideoRouteTapLink(
                video: video,
                openVideo: openVideo,
                prewarmVideoRoute: prewarmVideoRoute,
                onOpen: onOpen,
                label: label
            )
        } else {
            NavigationLink(value: video) {
                label()
            }
            .buttonStyle(VideoRoutePrewarmButtonStyle {
                onOpen?()
                prewarmVideoRoute?(video)
            })
        }
    }
}

private struct VideoRouteTapLink<Label: View>: View {
    let video: VideoItem
    let openVideo: (VideoItem) -> Void
    let prewarmVideoRoute: ((VideoItem) -> Void)?
    let onOpen: (() -> Void)?
    @ViewBuilder let label: () -> Label
    /// 第 17 轮：拖动期间禁止点按的共享状态（由详情页 tab view 提供，
    /// 其他地方为 nil = 不抑制）。简介/评论切换时页面跟手滑动，手指全程
    /// 停在同一张卡片上，松手时 Button 照常触发——allowsHitTesting 拦不住
    /// in-flight 的按压，所以在触发时拦。
    @Environment(\.videoDetailTapSuppression) private var tapSuppression

    var body: some View {
        Button(action: open) {
            label()
        }
        .buttonStyle(VideoRouteTapPrewarmButtonStyle {
            prewarmVideoRoute?(video)
        })
    }

    private func open() {
        // 第 17 轮：拖动刚结束时松手触发的点按直接跳过（页面还在落位动画里）。
        guard tapSuppression?.isSuppressed != true else { return }
        onOpen?()
        prewarmVideoRoute?(video)
        openVideo(video)
    }
}

private struct VideoRouteTapPrewarmButtonStyle: ButtonStyle {
    let onPress: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .onChange(of: configuration.isPressed) { _, isPressed in
                guard isPressed else { return }
                onPress()
            }
    }
}

private struct VideoRoutePrewarmButtonStyle: ButtonStyle {
    let onPress: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.94 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.smooth(duration: 0.12), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, isPressed in
                guard isPressed else { return }
                onPress()
            }
    }
}
