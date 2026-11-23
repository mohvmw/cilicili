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
    /// 跟手滑动的横向偏移（第 14 轮卡片滑动）：内容区手势 onChanged 里实时更新，
    /// 两页的 offset 都加上它，手指一动页面就跟着动。松手后归位/切换时再动画回 0。
    /// 注意：它不是动画值——onChanged 里直接赋值（无动画），只有松手归位/切换
    /// 时才包在 withAnimation 里；否则跟手会滞后。
    @State private var dragOffset: CGFloat = 0
    /// 跟手滑动的目标页（第 14 轮）：横滑方向上有相邻页时才有值。incoming 页
    /// 靠它提前挂载/显示（isPageVisible），否则滑动时滑入的是空白卡片。
    /// 切换成功时随 selection 一起清掉；弹回时动画结束后再清（见 snapDragBack）。
    @State private var dragTarget: VideoDetailContentTab? = nil
    /// 横滑方向是否已锁定（第 14 轮）：nil=未判定，true=横滑，false=竖滑。
    /// 一旦判定为竖滑，本次手势不再跟手，避免竖向滚动时页面横向抖动。
    @State private var isHorizontalDrag: Bool? = nil
    /// 跟手会话编号（第 14 轮）：每次横滑判定开始时 +1。弹回的延迟清理用它
    /// 校验，避免旧的延迟清理误删新一次滑动的目标页。
    @State private var dragSession = 0
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
                    .offset(x: pageOffset(for: tab))
                    .allowsHitTesting(selection == tab)
                    .accessibilityHidden(selection != tab)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(.smooth(duration: 0.28), value: selection)
        // 左右滑动切换 tab（原版卡片效果，第 14 轮）：横向占优的 DragGesture，
        // 用 simultaneous 挂在内容区外层，不抢竖向滚动——竖滑仍由各页自己的
        // 滚动视图接管。跟手时两页实时跟随手指；松手超过阈值完成切换、不足弹回。
        .simultaneousGesture(tabSwipeGesture)
        .background(VideoDetailTheme.background)
    }

    /// 选中页在 allCases 里的下标（第 14 轮卡片滑动的原点）。
    private var selectedIndex: Int {
        VideoDetailContentTab.allCases.firstIndex(of: selection) ?? 0
    }

    private func index(of tab: VideoDetailContentTab) -> Int {
        VideoDetailContentTab.allCases.firstIndex(of: tab) ?? 0
    }

    /// 该页是否应挂载/显示（第 14 轮卡片滑动）：当前页，或跟手滑动的目标页。
    /// 只影响挂载与可见性（评论页构造、UIKit 子树隐藏），不影响可点性
    /// （allowsHitTesting 仍只认 selection）与无障碍（仍只认 selection）。
    private func isPageVisible(_ tab: VideoDetailContentTab) -> Bool {
        tab == selection || tab == dragTarget
    }

    /// 该页的横向偏移（第 14 轮卡片滑动）：以选中页为原点，相邻页在左右各一页宽处，
    /// 再叠加跟手偏移。简介→评论：简介向左滑出、评论从右滑入；评论→简介反之。
    /// 点 tab 栏 / 画面滑动切 tab 时 dragOffset 为 0，selection 变化经上面的
    /// .animation(value: selection) 驱动滑动——与跟手是同一条偏移路径。
    private func pageOffset(for tab: VideoDetailContentTab) -> CGFloat {
        CGFloat(index(of: tab) - selectedIndex) * layoutWidth + dragOffset
    }

    /// 横滑方向上相邻的页（第 14 轮）：dx<0 左滑进下一页，dx>0 右滑回上一页；
    /// 边缘页无相邻页时返回 nil（不跟手、不切 tab）。
    private func adjacentTab(for translationX: CGFloat) -> VideoDetailContentTab? {
        let tabs = VideoDetailContentTab.allCases
        let targetIndex = translationX < 0 ? selectedIndex + 1 : selectedIndex - 1
        guard tabs.indices.contains(targetIndex) else { return nil }
        return tabs[targetIndex]
    }

    /// 左右滑动切 tab（原版卡片效果，第 14 轮）：左滑进下一页（简介→评论），
    /// 右滑回上一页（评论→简介）。经 toolbarSelection 切换，
    /// onSelectionWillChange 照常触发。跟手：onChanged 里横向占优时实时更新
    /// dragOffset，两页跟随手指；松手超过阈值（|dx|>60，沿用第 10 轮）完成
    /// 切换、不足弹回。注意：手势挂在 tabContent 外层，各页内部的竖向滚动
    /// （简介 UIScrollView、评论 UITableView）与横滑手势同时识别，竖滑由
    /// 方向锁定过滤掉，不会误切。第 13 轮：边缘开始的滑动不切 tab——从屏幕
    /// 左边缘开始的右滑留给系统返回（桥接层已把内容 pop 手势限定为边缘开始），
    /// 否则边缘右滑会一边返回一边切 tab。tabContent 占满宽度，
    /// startLocation.x 就是离左边缘的距离。
    private var tabSwipeGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                // 边缘开始的滑动不切 tab（留给系统返回），也不跟手。
                guard value.startLocation.x > 30 else { return }
                let translation = value.translation
                // 方向锁定：未判定时看总位移——横向占优且超过 8pt 判横滑，
                // 竖向占优且超过 8pt 判竖滑；一旦锁定不再改判，避免竖向滚动
                // 中途横向抖动，也避免横滑中途被竖向分量抢走。
                if let isHorizontal = isHorizontalDrag {
                    guard isHorizontal else { return }
                } else if abs(translation.width) > abs(translation.height),
                          abs(translation.width) > 8 {
                    isHorizontalDrag = true
                    dragSession += 1
                } else if abs(translation.height) > abs(translation.width),
                          abs(translation.height) > 8 {
                    isHorizontalDrag = false
                    return
                } else {
                    return
                }
                // 无相邻页的方向不跟手（边缘页再滑就是死胡同，dragOffset 归 0）。
                guard let target = adjacentTab(for: translation.width) else {
                    dragOffset = 0
                    dragTarget = nil
                    return
                }
                // 目标页先挂载（isPageVisible），再跟手滑入——否则滑入的是空白卡片。
                dragTarget = target
                // 夹取到一页宽：incoming 页最多滑到最终位置，不超滑。
                dragOffset = min(max(translation.width, -layoutWidth), layoutWidth)
            }
            .onEnded { value in
                defer { isHorizontalDrag = nil }
                // 非横滑（竖滑/斜滑/未判定）或边缘开始：不切 tab，弹回。
                guard isHorizontalDrag == true,
                      value.startLocation.x > 30
                else {
                    snapDragBack()
                    return
                }
                let translation = value.translation
                guard let target = adjacentTab(for: translation.width),
                      abs(translation.width) > 60
                else {
                    snapDragBack()
                    return
                }
                // 切换：selection 与 dragOffset 在同一个动画事务里一起变化——
                // incoming 页从跟手位置平滑滑到最终位置，不跳变；dragTarget 随
                // selection 一起清掉（incoming 页改由 selection 保持可见）。
                withAnimation(.smooth(duration: 0.28)) {
                    toolbarSelection.wrappedValue = target
                    dragOffset = 0
                    dragTarget = nil
                }
            }
    }

    /// 跟手偏移弹回 0（第 14 轮）：不足阈值 / 无相邻页 / 非横滑时不切 tab，
    /// 页面滑回原位。dragTarget 延迟到动画结束后再清——立即清的话，正在滑出的
    /// 卡片会在半路变空白（挂载被撤掉）；等它滑出屏幕（被 clipped 盖住）再清，
    /// 用户看不到。会话编号校验防止旧的延迟清理误删新一次滑动的目标页。
    private func snapDragBack() {
        let session = dragSession
        withAnimation(.smooth(duration: 0.28)) {
            dragOffset = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard dragSession == session else { return }
            dragTarget = nil
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
        // 第 14 轮卡片滑动：跟手目标页也要挂载，否则滑动时滑入的是空白卡片。
        // 只在拖动开始（横滑判定后）时挂载——用户已明确朝评论拖；不提前挂载，
        // 用户永远不打开评论时不白白拉取评论数据；拖后弹回的，已拉取的数据留作缓存。
        let mountsPageContent = mountsSecondaryContent
            || (tab == .comments && isPageVisible(.comments))
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
                        isActive: isPageVisible(tab),
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
                isActiveContent: isPageVisible(tab),
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
