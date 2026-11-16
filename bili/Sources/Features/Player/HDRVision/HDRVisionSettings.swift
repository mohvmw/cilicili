import Foundation

/// HDR 视界（HDR Vision）设置。
///
/// 脚本 `HDR 视界 (Userscript Port)` v1.1.0-us.1 的完整功能移植。
/// 默认值与脚本的 `HDV_DEFAULT_SETTINGS` 逐字一致。
/// 脚本里没有对应物的部分（图片增强、NijiLucid 接力、网页浮动面板）不在此列：
/// 播放器内只有一路视频，没有图片增强的载体。
struct HDRVisionSettings: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    /// 映射模式：BT.2446a 逆变换 / 幂函数曲线。
    enum MappingMode: String, Codable, CaseIterable, Identifiable, Sendable {
        case bt2446a
        case power

        var id: String { rawValue }

        var title: String {
            switch self {
            case .bt2446a: return "BT.2446a"
            case .power: return "幂函数"
            }
        }

        var detail: String {
            switch self {
            case .bt2446a: return "ITU-R BT.2446 方法 A 的逆变换，带中间调提升"
            case .power: return "暗部压缩 + 高光增强 + 亮度软钳制"
            }
        }
    }

    /// 幂函数模式预设（脚本 `POWER_PRESETS`）。
    enum PowerPreset: String, Codable, CaseIterable, Identifiable, Sendable {
        case standard
        case vivid
        case softNatural

        var id: String { rawValue }

        var title: String {
            switch self {
            case .standard: return "标准"
            case .vivid: return "鲜艳"
            case .softNatural: return "柔和自然"
            }
        }

        var detail: String {
            switch self {
            case .standard: return "柔和，日常/动画"
            case .vivid: return "明亮发光高光"
            case .softNatural: return "柔和光晕"
            }
        }
    }

    /// BT.2446a 模式预设（脚本 `BT2446A_PRESETS`）。
    enum BT2446aPreset: String, Codable, CaseIterable, Identifiable, Sendable {
        case standard
        case highDynamic
        case cinema

        var id: String { rawValue }

        var title: String {
            switch self {
            case .standard: return "标准"
            case .highDynamic: return "高动态"
            case .cinema: return "电影"
            }
        }

        var detail: String {
            switch self {
            case .standard: return "柔和自然"
            case .highDynamic: return "更高峰值与对比度"
            case .cinema: return "为电影优化"
            }
        }
    }

    var schemaVersion: Int = Self.schemaVersion

    /// 总开关。脚本默认 true；app 内默认关闭（用户在播放器上点 HDR 按钮或在设置里开启）。
    var enabled = false
    var mappingMode: MappingMode = .bt2446a
    var powerPreset: PowerPreset = .standard
    var bt2446aPreset: BT2446aPreset = .standard

    // MARK: - 幂函数模式参数（powerCurve）

    var powerExposure = 0.2
    var powerSaturation = 1.2
    var powerPeakBrightness = 10.0
    var powerBrightnessThreshold = 0.75
    var powerMaxBoost = 1.4
    var powerShadowThreshold = 0.15
    /// 脚本里无滑杆，只能由「鲜艳」预设设为 0.15；app 里给了滑杆。
    var powerShadowCrush = 0.0

    // MARK: - BT.2446a 模式参数（bt2446a）

    var btExposure = 0.0
    var btSaturation = 1.1
    var btPeakBrightness = 1.7
    var btBoost = 1.15
    var btMidToneLift = 0.35

    // MARK: - 画质与性能

    var debandEnabled = true
    /// 脚本里无滑杆，固定 0.012；app 里给了滑杆。
    var debandThreshold = 0.012
    var sharpenEnabled = false
    /// 脚本里无滑杆，固定 0.5；app 里给了滑杆。
    var sharpenStrength = 0.5
    /// 渲染分辨率缩放 0.25–1.0，对应 AVVideoComposition.renderScale。
    var renderScale = 1.0

    // MARK: - 当前模式的共用参数

    var activeExposure: Double {
        mappingMode == .bt2446a ? btExposure : powerExposure
    }

    var activeSaturation: Double {
        mappingMode == .bt2446a ? btSaturation : powerSaturation
    }

    var activePeakBrightness: Double {
        mappingMode == .bt2446a ? btPeakBrightness : powerPeakBrightness
    }

    /// 峰值亮度滑杆上限随模式变化（脚本行为）：BT 模式 6，幂函数模式 30。
    var peakBrightnessMaximum: Double {
        mappingMode == .bt2446a ? 6 : 30
    }

    // MARK: - 预设

    /// 应用一个幂函数预设（整组参数值 + 记录选择）。
    mutating func applyPreset(_ preset: PowerPreset) {
        powerPreset = preset
        switch preset {
        case .standard:
            powerBrightnessThreshold = 0.75
            powerMaxBoost = 1.4
            powerExposure = 0.2
            powerSaturation = 1.2
            powerPeakBrightness = 10
            powerShadowThreshold = 0.15
            powerShadowCrush = 0
        case .vivid:
            powerBrightnessThreshold = 0.55
            powerMaxBoost = 1.8
            powerExposure = 0.1
            powerSaturation = 1.2
            powerPeakBrightness = 30
            powerShadowThreshold = 0.15
            powerShadowCrush = 0.15
        case .softNatural:
            powerBrightnessThreshold = 0.7
            powerMaxBoost = 1.4
            powerExposure = 0.2
            powerSaturation = 1.1
            powerPeakBrightness = 10
            powerShadowThreshold = 0.15
            powerShadowCrush = 0
        }
    }

    /// 应用一个 BT.2446a 预设（整组参数值 + 记录选择）。
    mutating func applyPreset(_ preset: BT2446aPreset) {
        bt2446aPreset = preset
        switch preset {
        case .standard:
            btExposure = 0
            btSaturation = 1.1
            btPeakBrightness = 1.7
            btBoost = 1.15
            btMidToneLift = 0.35
        case .highDynamic:
            btExposure = 0
            btSaturation = 1.3
            btPeakBrightness = 1.1
            btBoost = 2.0
            btMidToneLift = 0
        case .cinema:
            btExposure = 0
            btSaturation = 1.0
            btPeakBrightness = 2.5
            btBoost = 1.05
            btMidToneLift = 0
        }
    }

    // MARK: - 持久化（与 DolbyVisionRenderingPolicy.stored(in:) 同形）

    static let storageKey = "cc.bili.playback.hdrVisionSettings.v1"

    /// 设置变化通知。LibraryStore 写入新设置时发出；播放引擎据此对当前视频
    /// 立即应用/移除滤镜，逐帧回调据此读取最新参数。
    static let didChangeNotification = Notification.Name("cc.bili.playback.hdrVisionSettingsDidChange")

    static let defaultValue = HDRVisionSettings()

    nonisolated static func stored(in userDefaults: UserDefaults = .standard) -> HDRVisionSettings {
        guard let data = userDefaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(HDRVisionSettings.self, from: data),
              decoded.schemaVersion == schemaVersion
        else {
            return defaultValue
        }
        return decoded
    }

    nonisolated static func store(_ settings: HDRVisionSettings, in userDefaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        userDefaults.set(data, forKey: storageKey)
    }
}

/// 供逐帧视频滤镜回调读取的当前设置。
///
/// 滤镜回调跑在 Core Image 的渲染队列上，不能碰 @MainActor 的 LibraryStore；
/// 这里用一把锁做线程安全的快照，LibraryStore 每次写入设置时同步更新它。
final class HDRVisionSettingsBox: @unchecked Sendable {
    static let shared = HDRVisionSettingsBox()

    private let lock = NSLock()
    private var _settings: HDRVisionSettings

    private init() {
        _settings = HDRVisionSettings.stored()
    }

    var settings: HDRVisionSettings {
        lock.withLock { _settings }
    }

    func update(_ settings: HDRVisionSettings) {
        lock.withLock { _settings = settings }
    }
}
