import SwiftUI

struct VideoDetailActionStripIconButton: View {
    /// 第 18 轮：拖动期间禁止点按的共享状态（简介页内容在 UIHostingController 里，
    /// 第 17 轮已在 scrollContent 显式注入环境，操作行在 summary 卡片里、能读到；
    /// 其他地方为 nil = 不抑制）。本组件只在操作行里用（点赞/投币/收藏）。
    @Environment(\.videoDetailTapSuppression) private var tapSuppression
    let accessibilityTitle: String
    let systemImage: String
    let foregroundStyle: Color
    let isDisabled: Bool
    let action: () -> Void
    let usesPlainStyle: Bool
    let dimsWhenDisabled: Bool
    let blocksTouches: Bool

    init(
        accessibilityTitle: String,
        systemImage: String,
        foregroundStyle: Color,
        isDisabled: Bool,
        action: @escaping () -> Void,
        usesPlainStyle: Bool = false,
        dimsWhenDisabled: Bool = true,
        blocksTouches: Bool = false
    ) {
        self.accessibilityTitle = accessibilityTitle
        self.systemImage = systemImage
        self.foregroundStyle = foregroundStyle
        self.isDisabled = isDisabled
        self.action = action
        self.usesPlainStyle = usesPlainStyle
        self.dimsWhenDisabled = dimsWhenDisabled
        self.blocksTouches = blocksTouches
    }

    var body: some View {
        Button(action: guardedAction) {
            VideoDetailActionStripIconLabel(
                systemImage: systemImage,
                foregroundStyle: foregroundStyle,
                side: VideoDetailActionStrip.Metrics.actionLabelSide,
                iconSize: VideoDetailActionStrip.Metrics.iconSize
            )
        }
        .videoDetailActionStripButtonAppearance(
            usesPlainStyle: usesPlainStyle,
            tint: usesPlainStyle ? foregroundStyle : nil
        )
        // Keep the full column tappable while the icon remains visually unadorned.
        .contentShape(Rectangle())
        .disabled(isDisabled)
        .allowsHitTesting(!blocksTouches)
        .opacity(isDisabled && dimsWhenDisabled ? 0.52 : 1)
        .accessibilityLabel(accessibilityTitle)
    }

    /// 第 18 轮：拖动期间禁止点按。Button 在松手、手指仍在其 bounds 内时触发；
    /// 跟手滑动时操作行跟着手指走，松手时仍在 Button 内，allowsHitTesting
    /// 拦不住 in-flight 按压，所以在触发时拦。环境默认 nil = 不抑制。
    private func guardedAction() {
        guard tapSuppression?.isSuppressed != true else { return }
        action()
    }
}

private struct VideoDetailActionStripButtonAppearanceModifier: ViewModifier {
    let usesPlainStyle: Bool
    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if usesPlainStyle {
            content
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .controlSize(.regular)
                .tint(tint ?? .secondary)
        } else {
            content
                .buttonBorderShape(.circle)
                .controlSize(.regular)
                .biliGlassButtonStyle()
        }
    }
}

extension View {
    func videoDetailActionStripButtonAppearance(
        usesPlainStyle: Bool,
        tint: Color? = nil
    ) -> some View {
        modifier(VideoDetailActionStripButtonAppearanceModifier(usesPlainStyle: usesPlainStyle, tint: tint))
    }
}
