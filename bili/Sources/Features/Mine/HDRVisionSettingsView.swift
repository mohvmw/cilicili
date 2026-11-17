import SwiftUI

/// HDR 视界设置页（独立页面）。
///
/// 脚本浮动面板的全部控件都搬到这里：总开关、映射模式、两组预设、全部参数滑杆、
/// 去色带/锐化、渲染缩放。脚本里没有滑杆的三个隐藏参数（去色带阈值、锐化强度、
/// 暗部压缩）在这里也给了滑杆。
struct HDRVisionSettingsView: View {
    @ObservedObject var libraryStore: LibraryStore
    @State private var settings: HDRVisionSettings

    init(libraryStore: LibraryStore) {
        self.libraryStore = libraryStore
        _settings = State(initialValue: libraryStore.hdrVisionSettings)
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Metal 内核")
                    Spacer()
                    Text(HDRVisionVideoFilter.kernelCompiled ? "已加载" : "编译失败")
                        .foregroundStyle(HDRVisionVideoFilter.kernelCompiled ? .secondary : .red)
                }
                HStack {
                    Text("当前画面")
                    Spacer()
                    Text(HDRVisionVideoFilter.lastApplyStatus)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("已处理帧 / 直通帧")
                    Spacer()
                    Text("\(HDRVisionVideoFilter.frameCounts.processed) / \(HDRVisionVideoFilter.frameCounts.passedThrough)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } header: {
                Text("状态（诊断）")
            } footer: {
                Text("内核编译失败，或直通帧一直涨而处理帧为 0，都说明滤镜没生效。打开本页时刷新；开关一次或重新进入可更新。")
            }

            Section {
                Toggle("启用 HDR 增强", isOn: boolBinding(\.enabled))
            } footer: {
                Text("仅对 SDR 视频生效；HDR10 / 杜比视界源视频会自动跳过（与脚本一致）。播放器底部也有 HDR 按钮，开关立即生效。")
            }

            Section {
                Picker("映射模式", selection: modeBinding) {
                    ForEach(HDRVisionSettings.MappingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(settings.mappingMode.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                presetRow
            } header: {
                Text("映射模式与预设")
            }

            Section {
                sliderRow("曝光", value: doubleBinding(activeExposureKeyPath), range: -2...2)
                sliderRow("饱和度", value: doubleBinding(activeSaturationKeyPath), range: 0...2)
                sliderRow("峰值亮度", value: doubleBinding(activePeakKeyPath), range: 1...settings.peakBrightnessMaximum)
            } header: {
                Text("基础")
            } footer: {
                Text("峰值亮度上限随模式变化：BT.2446a 为 6，幂函数为 30（与脚本一致）。")
            }

            if settings.mappingMode == .bt2446a {
                Section {
                    sliderRow("整体增强", value: doubleBinding(\.btBoost), range: 1...8)
                    sliderRow("画面提亮", value: doubleBinding(\.btMidToneLift), range: 0...1.5)
                } header: {
                    Text("BT.2446a")
                }
            } else {
                Section {
                    sliderRow("亮度阈值", value: doubleBinding(\.powerBrightnessThreshold), range: 0.3...1, percent: true)
                    sliderRow("最大增强", value: doubleBinding(\.powerMaxBoost), range: 1...3)
                    sliderRow("暗部阈值", value: doubleBinding(\.powerShadowThreshold), range: 0...1, percent: true)
                    sliderRow("暗部压缩", value: doubleBinding(\.powerShadowCrush), range: 0...0.5)
                } header: {
                    Text("幂函数")
                } footer: {
                    Text("暗部压缩在脚本里没有滑杆，只能由「鲜艳」预设设为 0.15；这里给了滑杆。")
                }
            }

            Section {
                Toggle("去色带", isOn: debandBinding)
                if settings.debandEnabled {
                    sliderRow("去色带阈值", value: doubleBinding(\.debandThreshold), range: 0.002...0.05, step: 0.001, decimals: 3)
                }
                Toggle("锐化", isOn: sharpenBinding)
                if settings.sharpenEnabled {
                    sliderRow("锐化强度", value: doubleBinding(\.sharpenStrength), range: 0...1)
                }
                sliderRow("渲染缩放", value: doubleBinding(\.renderScale), range: 0.25...1, step: 0.05, percent: true)
            } header: {
                Text("画质与性能")
            } footer: {
                Text("去色带与锐化互斥（与脚本面板一致）。去色带逐像素多尺度采样，比较耗 GPU；卡顿时可调低渲染缩放或关闭去色带。")
            }

            Section {
                Button("恢复默认设置", role: .destructive) {
                    resetToDefaults()
                }
            } footer: {
                Text("恢复脚本默认的全部参数（总开关保持当前状态）。预设基于 Windows SDR 亮度 35% 校准，不同设备效果略有差异。")
            }
        }
        .tint(libraryStore.appTintColor)
        .listStyle(.insetGrouped)
        .nativeTopScrollEdgeEffect()
        .hiddenInlineNavigationTitle()
        .onChange(of: libraryStore.hdrVisionSettings) { _, newValue in
            settings = newValue
        }
    }

    // MARK: - 预设行

    @ViewBuilder
    private var presetRow: some View {
        if settings.mappingMode == .bt2446a {
            HStack(spacing: 8) {
                ForEach(HDRVisionSettings.BT2446aPreset.allCases) { preset in
                    presetButton(title: preset.title, isSelected: settings.bt2446aPreset == preset) {
                        settings.applyPreset(preset)
                        commit()
                    }
                }
            }
        } else {
            HStack(spacing: 8) {
                ForEach(HDRVisionSettings.PowerPreset.allCases) { preset in
                    presetButton(title: preset.title, isSelected: settings.powerPreset == preset) {
                        settings.applyPreset(preset)
                        commit()
                    }
                }
            }
        }
    }

    private func presetButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                }
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? libraryStore.appTintColor : .secondary)
        .controlSize(.small)
    }

    // MARK: - 滑杆行

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double = 0.01,
        decimals: Int = 2,
        percent: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(formatted(value.wrappedValue, decimals: decimals, percent: percent))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func formatted(_ value: Double, decimals: Int, percent: Bool) -> String {
        if percent {
            return "\(Int((value * 100).rounded()))%"
        }
        return String(format: "%.\(decimals)f", value)
    }

    // MARK: - 绑定

    private var activeExposureKeyPath: WritableKeyPath<HDRVisionSettings, Double> {
        settings.mappingMode == .bt2446a ? \.btExposure : \.powerExposure
    }

    private var activeSaturationKeyPath: WritableKeyPath<HDRVisionSettings, Double> {
        settings.mappingMode == .bt2446a ? \.btSaturation : \.powerSaturation
    }

    private var activePeakKeyPath: WritableKeyPath<HDRVisionSettings, Double> {
        settings.mappingMode == .bt2446a ? \.btPeakBrightness : \.powerPeakBrightness
    }

    private func doubleBinding(_ keyPath: WritableKeyPath<HDRVisionSettings, Double>) -> Binding<Double> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                settings[keyPath: keyPath] = newValue
                commit()
            }
        )
    }

    private func boolBinding(_ keyPath: WritableKeyPath<HDRVisionSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                settings[keyPath: keyPath] = newValue
                commit()
            }
        )
    }

    private var modeBinding: Binding<HDRVisionSettings.MappingMode> {
        Binding(
            get: { settings.mappingMode },
            set: { newValue in
                settings.mappingMode = newValue
                commit()
            }
        )
    }

    /// 去色带与锐化互斥（脚本面板逻辑）。
    private var debandBinding: Binding<Bool> {
        Binding(
            get: { settings.debandEnabled },
            set: { newValue in
                settings.debandEnabled = newValue
                if newValue { settings.sharpenEnabled = false }
                commit()
            }
        )
    }

    private var sharpenBinding: Binding<Bool> {
        Binding(
            get: { settings.sharpenEnabled },
            set: { newValue in
                settings.sharpenEnabled = newValue
                if newValue { settings.debandEnabled = false }
                commit()
            }
        )
    }

    private func commit() {
        libraryStore.setHDRVisionSettings(settings)
    }

    private func resetToDefaults() {
        let enabled = settings.enabled
        settings = HDRVisionSettings.defaultValue
        settings.enabled = enabled
        commit()
    }
}
