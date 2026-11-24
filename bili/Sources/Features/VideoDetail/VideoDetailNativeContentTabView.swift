import SwiftUI

/// 第 20 轮：滚动视图原生 pan 的回调。translation = 手指累计位移（等价于
/// 旧 DragGesture 的 value.translation），startLocation = 落点（等价于
/// value.startLocation），state = pan 状态（.changed 走跟手逻辑，
/// .ended/.cancelled 走松手逻辑）。由两页滚动宿主经 onTabSwipePan 透传，
/// 在 Coordinator 里观察滚动视图自己的 panGestureRecognizer。
typealias VideoDetailTabSwipePanHandler = (CGSize, CGPoint, UIPanGestureRecognizer.State) -> Void

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
    /// 横滑锁定期间禁止两页内的其他动作（第 15 轮）：从横滑方向锁定开始，到松手后
    /// 落位动画结束（切换或弹回）为止。点按经 tabContent 的 allowsHitTesting 拦，
    /// 竖向滚动经透传到两页滚动容器的 isScrollEnabled 拦。
    @State private var suppressesPageInteractions = false
    /// 拖动期间禁止点按的共享状态（第 17 轮）：第一下 onChanged 就置上，松手落位
    /// 后清掉。点按处理（相关视频卡片、评论行）在触发时读它——allowsHitTesting
    /// 拦不住 in-flight 的 Button（见 VideoDetailTapSuppression）。
    /// @StateObject 持有唯一实例，引用稳定；@Published 变化会让本视图重渲染，
    /// 以便 allowsHitTesting 同步更新。
    @StateObject private var tapSuppression = VideoDetailTapSuppression()
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
                    // 第 15 轮：横滑锁定/落位期间禁止两页内的点按（相关视频卡片、
                    // 按钮等）。手势挂在 tabContent 外层（不在页上），关掉页的
                    // hit testing 不影响拖动本身。
                    // 第 17 轮：点按抑制提前到第一下拖动（tapSuppression 在
                    // onChanged 一开始就置上）。allowsHitTesting 只能拦新触点，
                    // in-flight 的 Button 靠各点按处理读 tapSuppression 拦；
                    // 这里多拦一层，顺带挡住拖动中另一根手指的新点按。
                    .allowsHitTesting(selection == tab && !suppressesPageInteractions && !tapSuppression.isSuppressed)
                    .accessibilityHidden(selection != tab)
            }
        }
        // 第 17 轮：把点按抑制状态透传给两页内容（纯 SwiftUI 的非 live 分支
        // 直接继承；live 分支的 UIHostingController 需在 scrollContent 里
        // 显式注入，评论页经 VideoDetailCommentsPageContext 透传）。
        .environment(\.videoDetailTapSuppression, tapSuppression)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .animation(.smooth(duration: 0.28), value: selection)
        // 第 20 轮：tab 切换手势不再是挂在内容区外层的 SwiftUI DragGesture。
        // 旧做法让 DragGesture 参与每一次触摸的识别，滚动视图的 pan 要等它
        // 失败（或满 minimumDistance 10pt）才开始，手指头 10–20pt 内内容不动，
        // 就是“不跟手”的粘滞感。改由两页滚动宿主观察滚动视图自己的
        // panGestureRecognizer（见 onTabSwipePan）：pan 是唯一的识别者，
        // 竖滑与首页一样跟手；横滑跟手逻辑不变（见 tabSwipePanHandler）。
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
    /// onSelectionWillChange 照常触发。跟手：onChanged 里横滑锁定后实时更新
    /// dragOffset，两页跟随手指；松手超过阈值（|dx|>60，沿用第 10 轮）完成
    /// 切换、不足弹回。注意：手势挂在 tabContent 外层，各页内部的竖向滚动
    /// （简介 UIScrollView、评论 UITableView）与横滑手势同时识别，竖滑由
    /// 方向锁定过滤掉，不会误切。第 13 轮：边缘开始的滑动不切 tab——从屏幕
    /// 左边缘开始的右滑留给系统返回（桥接层已把内容 pop 手势限定为边缘开始），
    /// 否则边缘右滑会一边返回一边切 tab。tabContent 占满宽度，
    /// startLocation.x 就是离左边缘的距离。
    /// 第 20 轮：tab 切换手势的 pan 回调，由两页滚动宿主经 onTabSwipePan 透传。
    /// 触发源从 SwiftUI DragGesture 换成滚动视图自己的 panGestureRecognizer
    /// （见 VideoDetailInteractiveScrollHost / VideoDetailCommentsTableViewHost
    /// 的 Coordinator）：pan 是滚动视图唯一的识别者，不再有祖先层 DragGesture
    /// 参与每一次触摸的识别，竖滑与首页一样跟手。跟手/锁定/松手逻辑与旧
    /// DragGesture 完全相同，只是 value.translation → translation、
    /// value.startLocation → startLocation、onChanged/onEnded → pan 的
    /// .changed/.ended 状态。点按抑制（第 17 轮）仍在第一下 pan 置上，
    /// 纯点按不产生 pan 回调，不误伤正常点击。
    private var tabSwipePanHandler: VideoDetailTabSwipePanHandler {
        { [self] translation, startLocation, state in
            switch state {
            case .began, .changed:
                handleTabSwipePanChanged(translation: translation, startLocation: startLocation)
            case .ended, .cancelled, .failed:
                handleTabSwipePanEnded(translation: translation, startLocation: startLocation)
            case .possible:
                break
            @unknown default:
                break
            }
        }
    }

    /// 第 20 轮：仅供非 live 分支（纯 SwiftUI ScrollView，初始播放阶段与
    /// UITest 夹具用）的 DragGesture。那里没有 UIKit 滚动视图可观察，保留旧的
    /// DragGesture 以免失去滑动切 tab；调的是同一套 handleTabSwipePanChanged/
    /// Ended（translation/startLocation 直接对应），行为与 live 分支一致。
    /// 生产主路径（live 分支）不走这里，走滚动视图自己的 pan 观察。
    private var tabSwipeDragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                handleTabSwipePanChanged(translation: value.translation, startLocation: value.startLocation)
            }
            .onEnded { value in
                handleTabSwipePanEnded(translation: value.translation, startLocation: value.startLocation)
            }
    }

    /// pan .changed 时的跟手逻辑（旧 tabSwipeGesture.onChanged 的等价改写）。
    private func handleTabSwipePanChanged(translation: CGSize, startLocation: CGPoint) {
        // 边缘开始的滑动不切 tab（留给系统返回），也不跟手。
        guard startLocation.x > 30 else { return }
        // 第 17 轮：第一下 pan（任何方向、位移很小）就抑制点按。纯点按不产生
        // pan 回调，所以不会误伤正常点击。点按抑制与滚动抑制拆开：点按抑制
        // 一有拖动就开；滚动抑制（isScrollEnabled=false）仍只在横滑锁定后开，
        // 竖向滚动不受影响。只在状态变化时赋值，避免 @Published 每次 pan
        // 都触发重渲染。
        if !tapSuppression.isSuppressed { tapSuppression.isSuppressed = true }
        // 方向锁定（第 17 轮改、第 19 轮把量级门 8→20，第 20 轮改跟手策略）：
        // 未判定时看总位移——锁定量级门仍是 20pt。起手前 ~10–15pt 的轨迹
        // 主要是落指噪声（按下时的一点下钩、手指初动的抖动），在 8pt 处判
        // 方向经常锁错：横滑起手带下钩被锁成竖滑 → 不切 tab；竖滑起手带横漂
        // 被锁成横滑 → isScrollEnabled=false 把滚动杀掉、页面只横向跟手
        // 再弹回；且锁定后不再改判，错一次整次手势都废。20pt 时有意方向已
        // 占主导，误锁率大幅下降。横滑判定：横向分量达到竖向分量的 0.7 倍
        // 即判横滑（约 55° 以内都算横滑，斜滑也能切 tab）。竖滑用互补条件，
        // 两者恰好互斥、无死区：|dx| > 0.7|dy| 与 |dy| > |dx|/0.7 必居其一。
        // 注意不能只放宽横滑条件而保留旧竖滑条件（|dy| > |dx|）：45°~55°
        // 的斜滑会先撞上竖滑门（|dy| 先到量级门）被判成竖滑，放宽就白做了。
        // 正常竖向滚动带少量横向漂移（通常 <30°）不会误切；漂到 55° 以内
        // 按用户要求算横滑。一旦锁定不再改判，避免竖向滚动中途横向抖动，
        // 也避免横滑中途被竖向分量抢走。切 tab 阈值仍是 |dx|>60（约 15%
        // 屏宽，防误切），本次不改。
        if let isHorizontal = isHorizontalDrag {
            guard isHorizontal else { return }
        } else if max(abs(translation.width), abs(translation.height)) > 20 {
            if abs(translation.width) > abs(translation.height) * 0.7 {
                isHorizontalDrag = true
                dragSession += 1
                // 第 15 轮：横滑锁定开始，禁止两页内的点按与竖向滚动，直到
                // 落位动画结束（切换或弹回，见 onEnded / snapDragBack 的延迟复位）。
                suppressesPageInteractions = true
            } else {
                isHorizontalDrag = false
                // 竖滑：竖向滚动由滚动视图自己取消点按（竖向 pan 手势会
                // 取消 Button 的按压），点按抑制在这里就恢复——竖滑结束
                // 后点按立即恢复，不留 0.35s 死区。
                tapSuppression.isSuppressed = false
                // 第 20 轮：同时清掉上一手势残留的滚动抑制。suppressesPageInteractions
                // 只在横滑锁定一处被置上、只在松手落位后的 0.35s 延迟里复位；
                // 若用户在 0.35s 窗口内又开始一次新的竖滑，旧的延迟复位还没跑到，
                // isScrollEnabled 仍是 false，本次竖滑的起手就被吃掉——连续滑动
                // 顿的根因之一。竖滑锁定时立即复位（本次手势是竖滑，不需要滚动
                // 抑制；即使上一手势的延迟复位稍后跑到，也只是重复清 false）。
                suppressesPageInteractions = false
                // 第 20 轮：若 8–20pt 间已有先行跟手（见下），竖滑锁定时把它
                // 平滑归 0（不留横向残影；0.15s 短动画，不与竖滑冲突）。
                if dragOffset != 0 || dragTarget != nil {
                    dragTarget = nil
                    withAnimation(.smooth(duration: 0.15)) { dragOffset = 0 }
                }
                return
            }
        } else if max(abs(translation.width), abs(translation.height)) > 8,
                  abs(translation.width) > abs(translation.height) * 0.7 {
            // 第 20 轮：锁定前先行跟手。旧逻辑在 20pt 量级门之前完全不跟手，
            // 锁定时 dragOffset 一次跳到约 20pt——手指动了 20pt、页面才突然跳，
            // 这就是横滑“不跟手”的死区，也是第 19 轮 20pt 门没解决问题的原因
            // （门越长，死区越大）。现改为：8pt 起、横向占优时先按横向分量跟手
            // （dragOffset 实时更新），到 20pt 再正式锁定；8–20pt 间若方向反转
            // 为竖滑（|dy| 占优），竖滑锁定分支把它平滑归 0，不留残影；松手时
            // 若仍未锁定，snapDragBack 弹回。8pt 门与 DragGesture 的
            // minimumDistance 10pt 同量级，纯点按不产生 pan 回调，不误伤点击；
            // 斜滑 45°~55° 仍按 0.7 比值判横滑，判定本身没变。
            guard let target = adjacentTab(for: translation.width) else {
                dragOffset = 0
                dragTarget = nil
                return
            }
            dragTarget = target
            dragOffset = min(max(translation.width, -layoutWidth), layoutWidth)
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

    /// pan .ended/.cancelled 时的松手逻辑（旧 tabSwipeGesture.onEnded 的等价改写）。
    private func handleTabSwipePanEnded(translation: CGSize, startLocation: CGPoint) {
        defer { isHorizontalDrag = nil }
        // 非横滑（竖滑/斜滑/未判定）或边缘开始：不切 tab，弹回。
        guard isHorizontalDrag == true,
              startLocation.x > 30
        else {
            snapDragBack()
            return
        }
        guard let target = adjacentTab(for: translation.width),
              abs(translation.width) > 60
        else {
            snapDragBack()
            return
        }
        // 切换：selection 与 dragOffset 在同一个动画事务里一起变化——
        // incoming 页从跟手位置平滑滑到最终位置，不跳变；dragTarget 随
        // selection 一起清掉（incoming 页改由 selection 保持可见）。
        // 第 15 轮：落位动画结束后再恢复两页内的点按与竖向滚动（0.35s =
        // 动画 0.28s + 余量，与 snapDragBack 同 pattern）。会话编号校验：
        // 落位期间若又开始一次新的横滑，旧的延迟清理不误删新锁定的禁止态。
        let session = dragSession
        withAnimation(.smooth(duration: 0.28)) {
            toolbarSelection.wrappedValue = target
            dragOffset = 0
            dragTarget = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard dragSession == session else { return }
            suppressesPageInteractions = false
            // 第 17 轮：同处恢复点按抑制（拖动期间点按处理一直在读它）。
            tapSuppression.isSuppressed = false
        }
    }

    /// 跟手偏移弹回 0（第 14 轮）：不足阈值 / 无相邻页 / 非横滑时不切 tab，
    /// 页面滑回原位。dragTarget 延迟到动画结束后再清——立即清的话，正在滑出的
    /// 卡片会在半路变空白（挂载被撤掉）；等它滑出屏幕（被 clipped 盖住）再清，
    /// 用户看不到。会话编号校验防止旧的延迟清理误删新一次滑动的目标页。
    /// 第 15 轮：同一处延迟复位也恢复两页内的点按与竖向滚动（横滑锁定期间禁止）。
    private func snapDragBack() {
        let session = dragSession
        withAnimation(.smooth(duration: 0.28)) {
            dragOffset = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard dragSession == session else { return }
            dragTarget = nil
            suppressesPageInteractions = false
            // 第 17 轮：同处恢复点按抑制。
            tapSuppression.isSuppressed = false
        }
    }

    /// 点 tab 栏时的强制复位（第 21 轮，第 20 轮回归的兜底）。
    /// dragOffset 与 suppressesPageInteractions 只在 pan 的 .ended/.cancelled
    /// 里复位，而 pan 被 isScrollEnabled=false 取消时 .cancelled 可能不送达
    /// target-action，导致两者卡住（页面错位 + 滚动全死）。点 tab 栏是用户
    /// 一定能触发的路径（Button 不受滚动抑制影响），在这里强制复位，保证点
    /// tab 后页面回正、滚动恢复。dragSession +1 让之前挂起的 0.35s 延迟复位
    /// 失效（已由本次复位代替，也防止旧复位在新拖动的 early-follow 阶段误删
    /// 刚置上的点按抑制）。
    /// 注意：只在 tab 栏 Button 里调，不要放进 toolbarSelection 的 setter——
    /// 滑动切 tab 也走 setter，放进去会把滑动切换的落位复位会话号冲掉
    /// （handleTabSwipePanEnded 先取 session、再经 setter 改 selection，
    /// setter 里 +1 会让它的 0.35s 延迟复位被会话校验拦掉，滚动抑制就一直
    /// 留着）。
    private func resetDragStateForTabBarTap() {
        dragSession += 1
        dragOffset = 0
        dragTarget = nil
        isHorizontalDrag = nil
        suppressesPageInteractions = false
        tapSuppression.isSuppressed = false
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
                    // 第 21 轮：点 tab 栏时强制复位拖动状态（第 20 轮回归的兜底）。
                    // dragOffset 与 suppressesPageInteractions 只在 pan 的
                    // .ended/.cancelled 里复位，而 pan 被 isScrollEnabled=false
                    // 取消时 .cancelled 可能不送达 target-action，导致两者卡住
                    // （页面错位 + 滚动全死）。点 tab 栏是用户一定能触发的路径
                    // （Button 不受滚动抑制影响），在这里强制复位，保证点 tab
                    // 后页面回正、滚动恢复。即使点的是当前 tab 也复位（selection
                    // 不变时 toolbarSelection 的 setter 直接返回，不会触发复位，
                    // 但卡住的状态仍需清掉）。
                    resetDragStateForTabBarTap()
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
                        // 第 22 轮：不再禁滚。横滑锁定时置 isScrollEnabled=false
                        // 会取消正在观察的 pan，导致 .ended 不送达、dragOffset
                        // 与抑制位卡死（第 21 轮的 scrollViewDidEndDragging
                        // 兜底在真机上也没触发）。竖向漂移的代价可以接受。
                        // 注意参数顺序：结构体里 suppressesScrolling 声明在
                        // showsBottomEdgeEffect 之前，调用时也必须在它之前，
                        // 否则编译报错（argument must precede）。
                        suppressesScrolling: false,
                        // 第 17 轮：拖动期间禁止点按的共享状态（引用类型，声明
                        // 在 suppressesScrolling 之后、showsBottomEdgeEffect
                        // 之前，调用顺序与声明一致）。
                        tapSuppression: tapSuppression,
                        // 第 20 轮：tab 切换的 pan 回调（滚动视图自己的 pan 观察者，
                        // 声明在 tapSuppression 之后、showsBottomEdgeEffect 之前，
                        // 调用顺序与声明一致）。
                        onTabSwipePan: tabSwipePanHandler,
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
                // 第 22 轮：不再禁滚（与 live 分支同理）。
                suppressesScrolling: false,
                // 第 17 轮：拖动期间禁止点按的共享状态（引用类型，声明在
                // suppressesScrolling 之后、content 之前，调用顺序与声明一致）。
                tapSuppression: tapSuppression,
                // 第 20 轮：tab 切换的 pan 回调（滚动视图自己的 pan 观察者，
                // 声明在 tapSuppression 之后、content 之前，调用顺序与声明一致）。
                onTabSwipePan: tabSwipePanHandler,
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
                // 第 22 轮：不再禁滚（与 live 分支同理）。
                suppressesScrolling: false,
                content: { _ in pageContent() }
            )
            // 第 20 轮：非 live 分支（纯 SwiftUI ScrollView，初始播放阶段与
            // UITest 夹具用）没有 UIKit 滚动视图可观察，保留旧的 DragGesture
            // （调同一套 handleTabSwipePanChanged/Ended）以免该分支失去滑动切 tab。
            // 生产主路径走 live 分支的 pan 观察，不受此影响。
            .simultaneousGesture(tabSwipeDragGesture)
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
    /// 横滑锁定/落位期间禁止竖向滚动（第 15 轮）。必须是 var：合成 memberwise
    /// init 会排除带默认值的 let，写 let 会导致调用方编译不过。
    var suppressesScrolling: Bool = false
    /// 拖动期间禁止点按的共享状态（第 17 轮，引用类型）。必须是 var：
    /// 与 suppressesScrolling 同理。声明在 suppressesScrolling 之后、
    /// content 之前，调用顺序与声明一致。
    var tapSuppression: VideoDetailTapSuppression? = nil
    /// tab 切换的 pan 回调（第 20 轮）：滚动视图自己的 pan 观察者。
    /// 必须是 var：与 suppressesScrolling 同理。声明在 tapSuppression 之后、
    /// content 之前，调用顺序与声明一致。
    var onTabSwipePan: VideoDetailTabSwipePanHandler? = nil
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
                suppressesScrolling: suppressesScrolling,
                tapSuppression: tapSuppression,
                onTabSwipePan: onTabSwipePan,
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
    /// 横滑锁定/落位期间禁止竖向滚动（第 15 轮）。必须是 var：合成 memberwise
    /// init 会排除带默认值的 let，写 let 会导致调用方编译不过。
    var suppressesScrolling: Bool = false
    /// 拖动期间禁止点按的共享状态（第 17 轮，引用类型）。必须是 var：
    /// 与 suppressesScrolling 同理。声明在 suppressesScrolling 之后、
    /// content 之前，调用顺序与声明一致。
    var tapSuppression: VideoDetailTapSuppression? = nil
    /// tab 切换的 pan 回调（第 20 轮）：滚动视图自己的 pan 观察者。
    /// 必须是 var：与 suppressesScrolling 同理。声明在 tapSuppression 之后、
    /// content 之前，调用顺序与声明一致。
    var onTabSwipePan: VideoDetailTabSwipePanHandler? = nil
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
        // 第 22 轮：suppressesScrolling 恒为 false（见上），此处恒为可滚。
        // 保留这行是为了不改结构体；禁滚的耦合已在源头移除。
        scrollView.isScrollEnabled = !suppressesScrolling
        scrollView.delegate = context.coordinator
        // 第 20 轮：观察滚动视图自己的 panGestureRecognizer（不新增识别器、
        // 不改 delegate，只是给已有的 pan 加一个 target）。pan 是滚动视图
        // 唯一的识别者，没有祖先层 DragGesture 参与识别，竖滑不再被拖住。
        // target 的回调在 Coordinator.handleTabSwipePan，回调闭包经 update
        // 同步进 Coordinator（与 onScrollOffsetChange 同 pattern）。
        scrollView.panGestureRecognizer.addTarget(
            context.coordinator,
            action: #selector(Coordinator.handleTabSwipePan(_:))
        )
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
            onTabSwipePan: onTabSwipePan,
            bottomInset: bottomInset,
            contentConfiguration: contentConfiguration
        )
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        // Opacity/accessibilityHidden on the SwiftUI wrapper does not reliably
        // remove a nested UIHostingController's UIKit subtree from VoiceOver.
        scrollView.accessibilityElementsHidden = !isActiveContent
        // 第 22 轮：suppressesScrolling 恒为 false，此处恒为可滚（见上）。
        scrollView.isScrollEnabled = !suppressesScrolling
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
            onTabSwipePan: onTabSwipePan,
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
            // 第 17 轮：UIHostingController 不继承外层 SwiftUI 环境，这里显式
            // 注入点按抑制状态。注入的是引用对象（身份不变），原地变值后卡片
            // 的点按处理在触发时读到最新值，不需要 rootView 重建。
            .environment(\.videoDetailTapSuppression, tapSuppression)
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
        /// tab 切换的 pan 回调（第 20 轮）：由 update 同步进来的闭包，见 handleTabSwipePan。
        private var onTabSwipePan: VideoDetailTabSwipePanHandler?
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
            onTabSwipePan: VideoDetailTabSwipePanHandler?,
            bottomInset: CGFloat,
            contentConfiguration: ContentConfiguration
        ) {
            isUpdatingView = true
            defer { isUpdatingView = false }
            let tabChanged = self.tab != tab
            self.tab = tab
            self.onScrollOffsetChange = onScrollOffsetChange
            self.onScrollPhaseChange = onScrollPhaseChange
            self.onTabSwipePan = onTabSwipePan
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

        /// 第 20 轮：滚动视图自己的 pan 的观察回调（makeUIView 里用 addTarget 挂上）。
        /// 不新增识别器、不改 delegate——只是读 pan 的位移/落点/状态，转发给 tab 视图
        /// 的 tabSwipePanHandler（跟手切 tab）。因为 pan 是滚动视图唯一的识别者，
        /// 没有祖先层 DragGesture 参与识别，竖滑不再被拖住。落点由当前位置减累计
        /// 位移还原（pan.translation 是从落点起的累计值），与旧 DragGesture 的
        /// value.startLocation 等价；边缘判定（x ≤ 30 留给系统返回）仍在 tab 视图
        /// 的 handleTabSwipePanChanged/Ended 里做。@objc 是 target-action 的要求；
        /// Coordinator 本身已是 @MainActor（UIScrollViewDelegate 方法同是 @objc），
        /// pan 回调在主线程触发，与 @MainActor 隔离一致。
        @objc fileprivate func handleTabSwipePan(_ pan: UIPanGestureRecognizer) {
            let scrollView = pan.view as? UIScrollView
            let translation = pan.translation(in: scrollView)
            let location = pan.location(in: scrollView)
            let startLocation = CGPoint(
                x: location.x - translation.x,
                y: location.y - translation.y
            )
            onTabSwipePan?(
                CGSize(width: translation.x, height: translation.y),
                startLocation,
                pan.state
            )
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
            // 第 21 轮：松手复位的兜底（第 20 轮回归）。dragOffset 与
            // suppressesPageInteractions 只在 pan 的 .ended/.cancelled 里复位，
            // 而 pan 被 isScrollEnabled=false 取消时 .cancelled 可能不送达
            // target-action，导致两者卡住（页面错位 + 滚动全死）。
            // scrollViewDidEndDragging 是 scroll view 自身的拖动结束通知，
            // 经 delegate 送达，不依赖 pan 的 target-action；在这里补一次
            // .ended 复位。若 pan 的 .ended 已先送达，这里是第二次调用——
            // handleTabSwipePanEnded/snapDragBack 是幂等的（isHorizontalDrag
            // 已被第一次调用的 defer 置 nil，第二次走 snapDragBack；两次
            // 0.35s 延迟复位用同一会话号，清的是同一批标志），不会二次切 tab。
            // 竖滑时 isHorizontalDrag 为 false，同样走 snapDragBack，
            // dragOffset 本来就是 0、标志本来就是关的，等于无操作。
            // 状态固定传 .ended 而不用 pan.state：若 pan 仍在 .changed 就
            // 传 .changed 会重新跟手，.ended 保证走复位路径。
            let pan = scrollView.panGestureRecognizer
            let translation = pan.translation(in: scrollView)
            let location = pan.location(in: scrollView)
            let startLocation = CGPoint(
                x: location.x - translation.x,
                y: location.y - translation.y
            )
            onTabSwipePan?(
                CGSize(width: translation.x, height: translation.y),
                startLocation,
                .ended
            )
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
    /// 横滑锁定/落位期间禁止竖向滚动（第 15 轮，与 live 分支同行为）。
    /// 必须是 var：合成 memberwise init 会排除带默认值的 let。
    var suppressesScrolling: Bool = false
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
            .scrollDisabled(suppressesScrolling)
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
