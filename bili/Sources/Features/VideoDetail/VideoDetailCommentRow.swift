import SwiftUI

struct CommentRow: View, Equatable {
    @AppStorage(CommentInteractionSettings.longPressActionsEnabledKey)
    private var longPressCommentActionsEnabled = false
    /// 第 17 轮：拖动期间禁止点按的共享状态（由详情页评论页透传，
    /// 其他地方为 nil = 不抑制）。切换 tab 时手指全程停在同一行评论上，
    /// 松手时整行回复 Button 照常触发——allowsHitTesting 拦不住
    /// in-flight 的按压，所以在触发时拦。
    @Environment(\.videoDetailTapSuppression) private var tapSuppression
    let item: VideoDetailCommentDisplayItem
    let style: CommentSectionStyle
    let showReplies: () -> Void
    let replyToComment: ((Comment) -> Void)?
    let onExpandText: (() -> Void)?

    private var comment: Comment { item.comment }
    private var display: VideoDetailCommentDisplayModel { item.display }

    init(
        item: VideoDetailCommentDisplayItem,
        style: CommentSectionStyle,
        showReplies: @escaping () -> Void,
        replyToComment: ((Comment) -> Void)? = nil,
        onExpandText: (() -> Void)? = nil
    ) {
        self.item = item
        self.style = style
        self.showReplies = showReplies
        self.replyToComment = replyToComment
        self.onExpandText = onExpandText
    }

    static func == (lhs: CommentRow, rhs: CommentRow) -> Bool {
        lhs.item == rhs.item
            && lhs.style == rhs.style
            && lhs.longPressCommentActionsEnabled == rhs.longPressCommentActionsEnabled
            && (lhs.replyToComment != nil) == (rhs.replyToComment != nil)
            && (lhs.onExpandText != nil) == (rhs.onExpandText != nil)
    }

    var body: some View {
        CommentRowLayout(
            fullRowReplyAction: commentTapAction,
            fullRowReplyAccessibilityLabel: "回复 \(display.authorName) 的评论"
        ) {
            CommentAvatar(
                urlString: display.avatarURLString,
                owner: display.authorOwner,
                size: 38
            )
        } header: {
            CommentRowHeader(comment: comment, display: display)
        } bodyContent: {
            CommentBodyText(
                content: comment.content,
                font: .subheadline,
                textColor: .primary,
                emoteSize: 21,
                typographyRole: .commentBody,
                onNonLinkTap: commentTapAction,
                onExpand: onExpandText
            )
                .fixedSize(horizontal: false, vertical: true)
        } media: {
            CommentImageButton(
                images: display.pictures,
                transitionScope: comment.id.description
            )
        } reply: {
            CommentRowReplyPreviewSection(
                display: display,
                isEnabled: style.showsReplyPreviewContainer,
                showReplies: guardedShowReplies,
                replyToComment: replyToComment
            )
        }
        .commentActionsMenu(
            longPressEnabled: longPressCommentActionsEnabled,
            text: comment.content?.message,
            copyTitle: "复制评论",
            replyAction: replyAction
        )
    }

    private var commentTapAction: (() -> Void)? {
        guard !longPressCommentActionsEnabled, let replyAction else { return nil }
        // 第 17 轮：拖动刚结束时松手触发的点按直接跳过（页面还在落位动画里）。
        // 这里同时覆盖整行回复 Button 与正文非链接点按（两者共用 commentTapAction）。
        // 闭包捕获的是共享对象引用（身份不变），触发时读到的 isSuppressed
        // 永远是最新值；CommentRow 是 Equatable，环境变化不触发重算也不影响。
        let tapSuppression = tapSuppression
        return {
            guard tapSuppression?.isSuppressed != true else { return }
            replyAction()
        }
    }

    /// 第 18 轮：回复预览的 showReplies 也要在触发时拦。CommentRow 把 showReplies
    /// 传给 CommentRowReplyPreviewSection，它再传给两处触发点：回复数 Button
    /// （CommentReplyPreviewContainer.replyCountAction 的“ N 条回复”）与预览行
    /// 点按（ReplyPreviewRow.commentTapAction = showReplies，经 onNonLinkTap）。
    /// 在这里包一层 guard，两处触发都拦住；showReplies 只在这里用，别处没有。
    /// 闭包捕获共享对象引用，触发时读到的 isSuppressed 永远是最新值。
    private var guardedShowReplies: () -> Void {
        let tapSuppression = tapSuppression
        return {
            guard tapSuppression?.isSuppressed != true else { return }
            showReplies()
        }
    }

    private var replyAction: (() -> Void)? {
        replyToComment.map { action in { action(comment) } }
    }
}
