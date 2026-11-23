import SwiftUI

struct VideoDetailNetworkDiagnosticsButton: View {
    /// 第 19 轮：拖动期间禁止点按的共享状态（只在简介页用，scrollContent 已注入环境）。
    @Environment(\.videoDetailTapSuppression) private var tapSuppression
    let action: () -> Void

    var body: some View {
        Button(action: guardedAction) {
            Label("网络诊断", systemImage: "waveform.path.ecg.rectangle")
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .accessibilityLabel("打开网络诊断")
    }

    /// 第 19 轮：拖动期间禁止点按。Button 在松手、手指仍在其 bounds 内时触发；
    /// 跟手滑动时简介页跟着手指走，松手时仍在 Button 内，allowsHitTesting
    /// 拦不住 in-flight 按压，所以在触发时拦。环境默认 nil = 不抑制。
    private func guardedAction() {
        guard tapSuppression?.isSuppressed != true else { return }
        action()
    }
}
