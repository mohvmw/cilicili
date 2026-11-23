import SwiftUI

struct VideoDetailNativeContentTabView<Content: View>: View {
    /// 滚动内容底部为底部栏（返回/写评论）预留的高度。原名 segmentedPickerHeight，
    /// 第 10 轮底部切换 pill 移走后改名：数值不变，底部栏仍在，预留空间照旧。
    private let bottomToolbarReservedHeight: CGFloat = 40
    /// 顶部 tab 栏高度（固定 44，与原版 tab 行同高）。live 分支下各页内容顶部留白
    /// 需在播放器高度之外再加这一段，否则 tab 栏会盖住简介页顶部的 UP 行。
    private let topTabBarHeight: CGFloat = 44
    @Environment(\.appThemeTintColor) private var appTintColor
    @Environment(\.videoDetailHasOuterBottomBar) private var hasOuterBottomBar
    @Binding var selection: VideoDetailContentTab
    let layoutWidth: CGFloat
    let topInset: CGFloat
    var standardHorizontalInset: CGFloat = 20
    var bottomInset: CGFloat = 0
    var scrollAdjustment: VideoDetailScrollAdjustment?
    let mountsSecondaryContent: Bool
    var hidesBottomToolbar = false
    var managesBottomToolbar = true
    var placesTopInsetInScrollContent = false
    var interactiveMinimumPlayerHeight = VideoDetailShellLayout.collapsedToolbarHeight
    /// 播放器实时高度（live 分支由容器经 ShellContentView.State 透传，即 playerFrame.height）。
    /// 顶部 tab 栏顶部贴着这个高度（播放器底部）。默认 0 表示未同步，
    /// 此时回退到 topInset（展开高度）。必须是 var：合成 memberwise init
    /// 会排除带默认值的 let，写 let 会导致调用方编译不过。
    var currentPlayerHeight: CGFloat = 0
    var contentRevision: Int = 0
    var onOpenCommentComposer: (() -> Void)?
    var onSelectionWillChange: ((VideoDetailContentTab) -> Void)? = nil
    let onScrollOffsetChange: ((VideoDetailContentTab, CGFloat) -> Void)?
    var onScrollPhaseChange: ((VideoDetailContentTab, ScrollPhase) -> Void)? = nil
    var summary: AnyView? = nil
    /// 评论 tab 的 UIKit 页面构造器。提供后评论页由 `UITableView` 自己滚动，
    /// 不再包在外层滚动宿主里（否则列表会被当成静态内容一次性布局）。
    var commentsPage: ((VideoDetailCommentsPageContext) -> AnyView)? = nil
    let content: (VideoDetailContentTab, Bool) -> Content

    var body: some View {
        Group {
            if placesTopInsetInScrollContent {
                // live 分支：内容区全屏，topInset 在每页滚动内容内部做透明留白，
                // 这里没有 VStack 可放 tab 栏——改用 ZStack 把 tab 栏盖在内容区顶部，
                // 顶部贴着播放器实时高度（播放器底部），固定不随内容滚动。
                ZStack(alignment: .top) {
                    tabContent
                    topTabBar
                        .offset(y: tabBarTopOffset)
                }
            } else {
                VStack(spacing: 0) {
                    Color.clear.frame(height: topInset).accessibilityHidden(true)
                    topTabBar
                    tabContent
                }
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .modifier(VideoDetailBottomToolbarModifier(
            isEnabled: managesBottomToolbar && !hasOuterBottomBar,
            isHidden: hidesBottomToolbar,
            selection: toolbarSelection,
            onOpenCommentComposer: onOpenCommentComposer
        ))
        .nativeBottomScrollEdgeBlur(isEnabled: !hidesBottomToolbar)
        .nativeBottomScrollEdgeBlurVisibility(isHidden: hidesBottomToolbar)
        .toolbarVisibility(.hidden, for: .tabBar)
        .tint(appTintColor)
        .environment(\.videoDetailStandardHorizontalInset, standardHorizontalInset)
    }

    private var tabContent: some View {
        ZStack {
            ForEach(VideoDetailContentTab.allCases) { tab in
                page(for: tab)
                    .opacity(selection == tab ? 1 : 0)
                    .allowsHitTesting(selection == tab)
                    .accessibilityHidden(selection != tab)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(.smooth(duration: 0.28), value: selection)
        // 左右滑动切换 tab（原版行为）：横向占优的 DragGesture，用 simultaneous
        // 挂在内容区外层，不抢竖向滚动——竖滑仍由各页自己的滚动视图接管。
        // 只有横向位移足够大且横向占优时才切 tab；竖向/斜向拖动一律放行。
        .simultaneousGesture(tabSwipeGesture)
        .background(VideoDetailTheme.background)
    }

    /// 左右滑动切 tab：左滑进下一页（简介→评论），右滑回上一页（评论→简介）。
    /// 经 toolbarSelection 切换，onSelectionWillChange 照常触发。
    /// 注意：手势挂在 tabContent 外层，各页内部的竖向滚动（简介 UIScrollView、
    /// 评论 UITableView）与横滑手势同时识别，竖滑由位移判断过滤掉，不会误切。
    private var tabSwipeGesture: some Gesture {
        DragGesture()
            .onEnded { value in
                let translation = value.translation
                guard abs(translation.width) > 60,
                      abs(translation.width) > abs(translation.height)
                else { return }
                let tabs = VideoDetailContentTab.allCases
                guard let index = tabs.firstIndex(of: selection) else { return }
                let targetIndex = translation.width < 0 ? index + 1 : index - 1
                guard tabs.indices.contains(targetIndex) else { return }
                toolbarSelection.wrappedValue = tabs[targetIndex]
            }
    }

    private var toolbarSelection: Binding<VideoDetailContentTab> {
        Binding(
            get: { selection },
            set: { newSelection in
                guard newSelection != selection else { return }
                onSelectionWillChange?(newSelection)
                selection = newSelection
            }
        )
    }

    /// live 分支下 tab 栏顶部的 y 偏移 = 播放器实时高度（即播放器底部）。
    /// currentPlayerHeight 为 0（尚未同步）时回退到 topInset（展开高度）。
    /// 播放器收起时该值随之变小，tab 栏贴着播放器底部上移，不留缝、不消失。
    private var tabBarTopOffset: CGFloat {
        currentPlayerHeight > 0 ? currentPlayerHeight : topInset
    }

    /// 顶部 tab 栏（第 10 轮）：播放器下方、内容上方，固定不随内容滚动。
    /// 样式对齐原版——“简介 / 评论”文字 tab，当前 tab 有下划线指示，左对齐。
    /// 点 tab 经 toolbarSelection 切换，与左右滑动切换共用同一绑定，下划线跟随 selection。
    /// 背景不透明：收起后内容从 tab 栏下方滑过时不透出来。
    private var topTabBar: some View {
        HStack(spacing: 24) {
            ForEach(VideoDetailContentTab.allCases) { tab in
                Button {
                    toolbarSelection.wrappedValue = tab
                } label: {
                    VStack(spacing: 6) {
                        Text(topTabBarTitle(tab))
                            .font(.system(size: 16, weight: selection == tab ? .semibold : .regular))
                            .foregroundStyle(selection == tab ? appTintColor : .secondary)
                        Capsule()
                            .fill(selection == tab ? appTintColor : Color.clear)
                            .frame(width: 20, height: 3)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(topTabBarTitle(tab))
            }
            Spacer()
        }
        .padding(.horizontal, standardHorizontalInset)
        .frame(height: topTabBarHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VideoDetailTheme.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
        .animation(.smooth(duration: 0.28), value: selection)
    }

    /// 顶部 tab 栏的文案：对齐底部切换器（VideoDetailToolbarSegmentedPickerView）
    /// 与原版——简介 / 评论。枚举自身的 title 是“详情”，此处不用。
    private func topTabBarTitle(_ tab: VideoDetailContentTab) -> String {
        switch tab {
        case .detail: return "简介"
        case .comments: return "评论"
        }
    }

    @ViewBuilder
    private func page(for tab: VideoDetailContentTab) -> some View {
        let mountsPageContent = mountsSecondaryContent
            || (tab == .comments && selection == .comments)
        let pageContent = {
            content(tab, mountsPageContent)
        }
        if placesTopInsetInScrollContent, tab == .comments, let commentsPage {
            if mountsPageContent {
                commentsPage(
                    VideoDetailCommentsPageContext(
                        tab: tab,
                        // live 分支内容顶部留白 = 播放器高度 + tab 栏高度：
                        // tab 栏固定盖在播放器下方，内容要从 tab 栏下方开始，
                        // 否则 tab 栏会盖住评论列表顶部。收起/展开时该留白不变，
                        // 内容随滚动上移、从 tab 栏下方滑过（tab 栏背景不透明）。
                        topInset: topInset + topTabBarHeight,
                        bottomInset: bottomInset + bottomToolbarReservedHeight + 16,
                        minimumPlayerHeight: interactiveMinimumPlayerHeight,
                        standardHorizontalInset: standardHorizontalInset,
                        isActive: selection == tab,
                        showsBottomEdgeEffect: !hidesBottomToolbar,
                        scrollAdjustment: scrollAdjustment,
                        onScrollOffsetChange: onScrollOffsetChange,
                        onScrollPhaseChange: onScrollPhaseChange
                    )
                )
            } else {
                Color.clear
            }
        } else if placesTopInsetInScrollContent {
            VideoDetailInteractiveScrollingTabPage(
                tab: tab,
                scrollAdjustment: scrollAdjustment,
                onScrollOffsetChange: onScrollOffsetChange,
                onScrollPhaseChange: onScrollPhaseChange,
                summary: tab == .detail ? summary : nil,
                // 同上：简介页内容顶部留白 = 播放器高度 + tab 栏高度，
                // 否则 tab 栏会盖住简介页顶部的 UP 行。
                topInset: topInset + topTabBarHeight,
                minimumPlayerHeight: interactiveMinimumPlayerHeight,
                bottomEdgeBlurEnabled: !hidesBottomToolbar,
                isActiveContent: selection == tab,
                contentRevision: contentRevision,
                contentMountsSecondaryContent: mountsPageContent,
                bottomInset: bottomInset + bottomToolbarReservedHeight + 16,
                standardHorizontalInset: standardHorizontalInset,
                content: pageContent
            )
        } else {
            VideoDetailScrollingTabPage(
                tab: tab,
                scrollAdjustment: scrollAdjustment,
                onScrollOffsetChange: onScrollOffsetChange,
                onScrollPhaseChange: onScrollPhaseChange,
                summary: tab == .detail ? summary : nil,
                topInset: 0,
                minimumPlayerHeight: 0,
                bottomInset: bottomInset + bottomToolbarReservedHeight + 16,
                standardHorizontalInset: standardHorizontalInset,
                content: { _ in pageContent() }
            )
        }
    }
}

@MainActor
private struct VideoDetailInteractiveScrollingTabPage<Content: View>: View {
    let tab: VideoDetailContentTab
    let scrollAdjustment: VideoDetailScrollAdjustment?
    let onScrollOffsetChange: ((VideoDetailContentTab, CGFloat) -> Void)?
    let onScrollPhaseChange: ((VideoDetailContentTab, ScrollPhase) -> Void)?
    let summary: AnyView?
    let topInset: CGFloat
    let minimumPlayerHeight: CGFloat
    let bottomEdgeBlurEnabled: Bool
    let isActiveContent: Bool
    let contentRevision: Int
    let contentMountsSecondaryContent: Bool
    let bottomInset: CGFloat
    let standardHorizontalInset: CGFloat
    let content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            VideoDetailInteractiveScrollHost(
                tab: tab,
                viewportHeight: proxy.size.height,
                scrollAdjustment: scrollAdjustment,
                onScrollOffsetChange: onScrollOffsetChange,
                onScrollPhaseChange: onScrollPhaseChange,
                summary: summary,
                topInset: topInset,
                minimumPlayerHeight: minimumPlayerHeight,
                bottomEdgeBlurEnabled: bottomEdgeBlurEnabled,
                isActiveContent: isActiveContent,
                contentRevision: contentRevision,
                contentMountsSecondaryContent: contentMountsSecondaryContent,
                bottomInset: bottomInset,
                standardHorizontalInset: standardHorizontalInset,
                content: content
            )
        }
    }
}

@MainActor
private struct VideoDetailInteractiveScrollHost<Content: View>: UIViewRepresentable {
    let tab: VideoDetailContentTab
    let viewportHeight: CGFloat
    let scrollAdjustment: VideoDetailScrollAdjustment?
    let onScrollOffsetChange: ((VideoDetailContentTab, CGFloat) -> Void)?
    let onScrollPhaseChange: ((VideoDetailContentTab, ScrollPhase) -> Void)?
    let summary: AnyView?
    let topInset: CGFloat
    let minimumPlayerHeight: CGFloat
    let bottomEdgeBlurEnabled: Bool
    let isActiveContent: Bool
    let contentRevision: Int
    let contentMountsSecondaryContent: Bool
    let bottomInset: CGFloat
    let standardHorizontalInset: CGFloat
    let content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = VideoDetailEdgeEffectScrollView()
        scrollView.accessibilityElementsHidden = !isActiveContent
        scrollView.alwaysBounceVertical = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = context.coordinator
        scrollView.configureBottomEdgeEffect(enabled: bottomEdgeBlurEnabled, isActiveContent: isActiveContent)

        let hostingController = UIHostingController(rootView: scrollContent)
        hostingController.sizingOptions = .intrinsicContentSize
        hostingController.safeAreaRegions = []
        hostingController.view.backgroundColor = .clear
        hostingController.view.isHidden = !isActiveContent
        hostingController.view.accessibilityElementsHidden = !isActiveContent
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            hostingController.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
        context.coordinator.hostingController = hostingController
        context.coordinator.update(
            scrollView: scrollView,
            tab: tab,
            scrollAdjustment: scrollAdjustment,
            onScrollOffsetChange: onScrollOffsetChange,
            onScrollPhaseChange: onScrollPhaseChange,
            bottomInset: bottomInset,
            contentConfiguration: contentConfiguration
        )
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        // Opacity/accessibilityHidden on the SwiftUI wrapper does not reliably
        // remove a nested UIHostingController's UIKit subtree from VoiceOver.
        scrollView.accessibilityElementsHidden = !isActiveContent
        (scrollView as? VideoDetailEdgeEffectScrollView)?.configureBottomEdgeEffect(
            enabled: bottomEdgeBlurEnabled, isActiveContent: isActiveContent
        )
        // This hosting view has its own accessibility root. Hide that root as
        // well as the scroll view while retaining its layout and scroll offset.
        context.coordinator.hostingController?.view.isHidden = !isActiveContent
        context.coordinator.hostingController?.view.accessibilityElementsHidden = !isActiveContent
        let contentChanged = context.coordinator.contentConfiguration != contentConfiguration
        if contentChanged {
            context.coordinator.hostingController?.rootView = scrollContent
            context.coordinator.contentConfiguration = contentConfiguration
        }
        context.coordinator.update(
            scrollView: scrollView,
            tab: tab,
            scrollAdjustment: scrollAdjustment,
            onScrollOffsetChange: onScrollOffsetChange,
            onScrollPhaseChange: onScrollPhaseChange,
            bottomInset: bottomInset,
            contentConfiguration: contentConfiguration
        )
    }

    static func dismantleUIView(_ scrollView: UIScrollView, coordinator: Coordinator) {
        (scrollView as? VideoDetailEdgeEffectScrollView)?.configureBottomEdgeEffect(enabled: false, isActiveContent: false)
        scrollView.delegate = nil
        coordinator.hostingController?.view.removeFromSuperview()
        coordinator.hostingController = nil
    }

    private var scrollContent: AnyView {
        return AnyView(
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: topInset)
                    .accessibilityHidden(true)
                LazyVStack(spacing: 12) {
                    summary
                    content()
                }
                .padding(.top, 12)
            }
            .frame(
                minHeight: VideoDetailShellLayout.scrollContentMinimumHeight(
                    viewportHeight: viewportHeight,
                    expandedPlayerHeight: topInset,
                    minimumPlayerHeight: minimumPlayerHeight
                ),
                alignment: .top
            )
            .environment(
                \.videoDetailCommentsEmptyStateMinimumHeight,
                max(viewportHeight - bottomInset, 0)
            )
            .environment(\.videoDetailStandardHorizontalInset, standardHorizontalInset)
        )
    }

    private var contentConfiguration: ContentConfiguration {
        ContentConfiguration(
            viewportHeight: viewportHeight,
            topInset: topInset,
            minimumPlayerHeight: minimumPlayerHeight,
            contentRevision: contentRevision,
            contentMountsSecondaryContent: contentMountsSecondaryContent
        )
    }

    fileprivate struct ContentConfiguration: Equatable {
        let viewportHeight: CGFloat
        let topInset: CGFloat
        let minimumPlayerHeight: CGFloat
        let contentRevision: Int
        let contentMountsSecondaryContent: Bool
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var hostingController: UIHostingController<AnyView>?
        fileprivate var contentConfiguration: ContentConfiguration?
        private var tab: VideoDetailContentTab?
        private var onScrollOffsetChange: ((VideoDetailContentTab, CGFloat) -> Void)?
        private var onScrollPhaseChange: ((VideoDetailContentTab, ScrollPhase) -> Void)?
        private var appliedScrollAdjustmentToken: Int?
        private var isApplyingScrollAdjustment = false
        private var virtualScrollOffset: CGFloat = 0
        private var lastReportedVirtualScrollOffset: CGFloat?
        private var pendingReportedScroll: (tab: VideoDetailContentTab, offset: CGFloat)?
        private var isReportScheduled = false
        private var hasUserScrolled = false
        private var isUpdatingView = false

        fileprivate func update(
            scrollView: UIScrollView,
            tab: VideoDetailContentTab,
            scrollAdjustment: VideoDetailScrollAdjustment?,
            onScrollOffsetChange: ((VideoDetailContentTab, CGFloat) -> Void)?,
            onScrollPhaseChange: ((VideoDetailContentTab, ScrollPhase) -> Void)?,
            bottomInset: CGFloat,
            contentConfiguration: ContentConfiguration
        ) {
            isUpdatingView = true
            defer { isUpdatingView = false }
            let tabChanged = self.tab != tab
            self.tab = tab
            self.onScrollOffsetChange = onScrollOffsetChange
            self.onScrollPhaseChange = onScrollPhaseChange
            self.contentConfiguration = contentConfiguration
            if tabChanged {
                lastReportedVirtualScrollOffset = nil
                pendingReportedScroll = nil
            }
            let resolvedBottomInset = max(bottomInset, 0)
            if scrollView.contentInset.bottom != resolvedBottomInset {
                scrollView.contentInset.bottom = resolvedBottomInset
                scrollView.verticalScrollIndicatorInsets.bottom = resolvedBottomInset
            }

            if !scrollView.isTracking && !scrollView.isDecelerating {
                applyVirtualScrollOffset(virtualScrollOffset, to: scrollView)
            }

            guard let scrollAdjustment,
                  scrollAdjustment.tab == tab,
                  appliedScrollAdjustmentToken != scrollAdjustment.token
            else { return }
            appliedScrollAdjustmentToken = scrollAdjustment.token
            applyVirtualScrollOffset(scrollAdjustment.offset, to: scrollView)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            guard let tab else { return }
            hasUserScrolled = true
            onScrollPhaseChange?(tab, .tracking)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isApplyingScrollAdjustment, let tab else { return }

            guard hasUserScrolled else {
                applyVirtualScrollOffset(0, to: scrollView)
                return
            }

            virtualScrollOffset = max(0, scrollView.contentOffset.y)

            reportScrollOffset(
                tab: tab,
                offset: virtualScrollOffset,
                immediately: !isUpdatingView && (scrollView.isDragging || scrollView.isDecelerating)
            )
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            guard let tab else { return }
            onScrollPhaseChange?(tab, decelerate ? .decelerating : .idle)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            guard let tab else { return }
            applyVirtualScrollOffset(max(0, scrollView.contentOffset.y), to: scrollView)
            if hasUserScrolled {
                reportScrollOffset(tab: tab, offset: virtualScrollOffset)
            }
            onScrollPhaseChange?(tab, .idle)
        }

        private func applyVirtualScrollOffset(
            _ offset: CGFloat,
            to scrollView: UIScrollView
        ) {
            let normalizedOffset = max(offset, 0)
            virtualScrollOffset = normalizedOffset
            let contentOffset = normalizedOffset

            guard abs(scrollView.contentOffset.y - contentOffset) > 0.5 else { return }
            isApplyingScrollAdjustment = true
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: contentOffset),
                animated: false
            )
            isApplyingScrollAdjustment = false
        }

        private func reportScrollOffset(
            tab: VideoDetailContentTab,
            offset: CGFloat,
            immediately: Bool = false
        ) {
            guard lastReportedVirtualScrollOffset.map({ abs($0 - offset) > 0.5 }) ?? true else {
                return
            }
            lastReportedVirtualScrollOffset = offset
            if immediately {
                pendingReportedScroll = nil
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    onScrollOffsetChange?(tab, offset)
                }
                return
            }
            pendingReportedScroll = (tab, offset)
            guard !isReportScheduled else { return }
            isReportScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isReportScheduled = false
                guard let report = self.pendingReportedScroll
                else { return }
                self.pendingReportedScroll = nil
                guard self.tab == report.tab else { return }
                self.onScrollOffsetChange?(report.tab, report.offset)
            }
        }
    }
}

private struct VideoDetailScrollingTabPage<Content: View>: View {
    let tab: VideoDetailContentTab
    let scrollAdjustment: VideoDetailScrollAdjustment?
    let onScrollOffsetChange: ((VideoDetailContentTab, CGFloat) -> Void)?
    let onScrollPhaseChange: ((VideoDetailContentTab, ScrollPhase) -> Void)?
    let summary: AnyView?
    let topInset: CGFloat
    let minimumPlayerHeight: CGFloat
    let bottomInset: CGFloat
    let standardHorizontalInset: CGFloat
    @ViewBuilder let content: (VideoDetailContentTab) -> Content
    @State private var position = ScrollPosition()

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                scrollStack
                .padding(.top, 12)
                .frame(
                    minHeight: minimumScrollableContentHeight(viewportHeight: proxy.size.height),
                    alignment: .top
                )
            }
            .environment(
                \.videoDetailCommentsEmptyStateMinimumHeight,
                topInset > 0 ? max(proxy.size.height - bottomInset, 0) : 0
            )
            .environment(\.videoDetailStandardHorizontalInset, standardHorizontalInset)
            .scrollPosition($position)
            .contentMargins(.bottom, bottomInset, for: .scrollContent)
            .scrollIndicators(.hidden)
            .nativeTopScrollEdgeEffect()
            .onScrollGeometryChange(for: CGFloat.self) {
                max(0, $0.contentOffset.y + $0.contentInsets.top)
            } action: { _, offset in
                onScrollOffsetChange?(tab, offset)
            }
            .onScrollPhaseChange { _, phase in
                onScrollPhaseChange?(tab, phase)
            }
            .onChange(of: scrollAdjustment) { _, adjustment in
                guard let adjustment, adjustment.tab == tab else { return }
                position.scrollTo(y: adjustment.offset)
            }
        }
    }

    private func minimumScrollableContentHeight(viewportHeight: CGFloat) -> CGFloat {
        VideoDetailShellLayout.scrollContentMinimumHeight(
            viewportHeight: viewportHeight,
            expandedPlayerHeight: topInset,
            minimumPlayerHeight: minimumPlayerHeight
        )
    }

    @ViewBuilder
    private var scrollStack: some View {
        if topInset > 0, minimumPlayerHeight > 0 {
            LazyVStack(spacing: 12) {
                Color.clear
                    .frame(height: topInset)
                    .accessibilityHidden(true)
                summary
                content(tab)
            }
        } else {
            LazyVStack(spacing: 12) {
                summary
                content(tab)
            }
        }
    }
}

/// Declared by the navigation page for the UIKit shell, rather than its child host.
struct VideoDetailBottomToolbarModifier: ViewModifier {
    @Environment(\.navigationHistoryContext) private var navigationHistory
    var isEnabled = true
    let isHidden: Bool
    /// 保留形参：外层调用方（VideoDetailViewContent）仍传入 selection。
    /// 底部栏自第 10 轮起不再用它切换 tab（切换 pill 已移到顶部 tab 栏），
    /// 这里只保留返回与写评论两个入口。
    @Binding var selection: VideoDetailContentTab
    let onOpenCommentComposer: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .toolbar {
                    if let navigationHistory {
                        ToolbarItem(placement: .bottomBar) {
                            VideoDetailHistoryBackMenu(history: navigationHistory)
                        }
                    }
                    // 底部只保留写评论入口：简介/评论切换 pill 已移到顶部 tab 栏，
                    // 这里不再放 VideoDetailToolbarSegmentedPickerView。
                    if let onOpenCommentComposer {
                        ToolbarSpacer(.flexible, placement: .bottomBar)
                        ToolbarItem(placement: .bottomBar) {
                            VideoDetailToolbarCommentAction(onComment: onOpenCommentComposer)
                        }
                        .sharedBackgroundVisibility(.automatic)
                    }
                }
                .toolbarBackground(.automatic, for: .bottomBar)
                .toolbarVisibility(isHidden ? .hidden : .automatic, for: .bottomBar)
        } else {
            content
        }
    }
}

private struct VideoDetailHasOuterBottomBarKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var videoDetailHasOuterBottomBar: Bool {
        get { self[VideoDetailHasOuterBottomBarKey.self] }
        set { self[VideoDetailHasOuterBottomBarKey.self] = newValue }
    }
}
