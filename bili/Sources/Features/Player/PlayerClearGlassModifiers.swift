import SwiftUI

extension View {
    @ViewBuilder
    func biliPlayerCompactGlassCircle(
        metrics: PlayerNativeControlMetrics,
        isEnabled: Bool = true
    ) -> some View {
        buttonStyle(.plain)
            .contentShape(Circle())
            .biliPlayerClearGlass(interactive: true, in: Circle(), isEnabled: isEnabled)
            .biliPlayerExpandedHitTarget(metrics: metrics)
    }

    @ViewBuilder
    func biliPlayerCompactGlassCapsule(
        metrics: PlayerNativeControlMetrics,
        isEnabled: Bool = true
    ) -> some View {
        buttonStyle(.plain)
            .contentShape(Capsule())
            .biliPlayerClearGlass(interactive: true, in: Capsule(), isEnabled: isEnabled)
            .biliPlayerExpandedHitTarget(metrics: metrics)
    }

    @ViewBuilder
    func biliPlayerClearGlass<S: Shape>(
        interactive: Bool,
        in shape: S,
        isEnabled: Bool = true
    ) -> some View {
        if isEnabled {
            modifier(BiliPlayerClearGlassModifier(interactive: interactive, shape: shape))
        } else {
            self
        }
    }

    func biliPlayerExpandedHitTarget(horizontal: CGFloat = 4, vertical: CGFloat = 8) -> some View {
        padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .contentShape(Rectangle())
            .padding(.horizontal, -horizontal)
            .padding(.vertical, -vertical)
    }

    func biliPlayerExpandedHitTarget(metrics: PlayerNativeControlMetrics) -> some View {
        // 横向外扩钳制到行内间距的一半：相邻按钮的热区若重叠，重叠带里的
        // 点按会被判给后一个兄弟视图。点播时弹幕按钮隐藏，HDR 与全屏直接
        // 相邻，竖屏热区各扩 8pt、间距 4pt，重叠 12pt，点 HDR 右侧会变全屏。
        // 钳制后竖屏横向 2pt、横屏 3pt，热区仍有 32–40pt 宽，重叠消失。
        // 纵向没有相邻按钮，不动。
        let horizontal = min(max((44 - metrics.controlHeight) / 2, 4), metrics.controlSpacing / 2)
        let vertical = max((44 - metrics.controlHeight) / 2, 8)
        return biliPlayerExpandedHitTarget(horizontal: horizontal, vertical: vertical)
    }
}

struct BiliPlayerGlassSheetBackground: View {
    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .biliRegularGlassEffect(interactive: false, in: Rectangle())
    }
}

private struct BiliPlayerClearGlassModifier<GlassShape: Shape>: ViewModifier {
    let interactive: Bool
    let shape: GlassShape

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(
                .clear
                    .interactive(interactive),
                in: shape
            )
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}
