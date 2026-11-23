import UIKit

@MainActor
enum AppOrientationLock {
    private(set) static var supportedOrientations: UIInterfaceOrientationMask = .portrait

    static func update(
        to orientations: UIInterfaceOrientationMask,
        in scene: UIWindowScene?,
        requestsGeometryUpdate: Bool = false
    ) {
        let didChange = supportedOrientations != orientations
        supportedOrientations = orientations

        let targetScenes = scenes(matching: scene)
        guard didChange || requestsGeometryUpdate else { return }
        requestInterfaceUpdates(in: targetScenes)

        guard requestsGeometryUpdate else { return }
        requestGeometryUpdate(to: orientations, in: targetScenes)
    }

    static func restorePortrait(in scene: UIWindowScene? = nil) {
        let targetScenes = scenes(matching: scene)
        let needsGeometryUpdate = targetScenes.contains {
            !$0.effectiveGeometry.interfaceOrientation.isPortrait
        }
        guard supportedOrientations != .portrait || needsGeometryUpdate else { return }
        supportedOrientations = .portrait
        requestInterfaceUpdates(in: targetScenes)
        guard needsGeometryUpdate else { return }
        requestGeometryUpdate(to: .portrait, in: targetScenes)
    }

    static func requestGeometryUpdate(
        to orientations: UIInterfaceOrientationMask,
        in scene: UIWindowScene?,
        onError: (@MainActor (Error) -> Void)? = nil
    ) {
        requestGeometryUpdate(to: orientations, in: scenes(matching: scene), onError: onError)
    }

    private static func scenes(matching scene: UIWindowScene?) -> [UIWindowScene] {
        if let scene {
            return [scene]
        }
        return UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    }

    private static func requestInterfaceUpdates(in scenes: [UIWindowScene]) {
        scenes
            .flatMap(\.windows)
            .filter(\.participatesInAppOrientationChrome)
            .compactMap(\.rootViewController)
            .forEach { controller in
                controller.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller.setNeedsStatusBarAppearanceUpdate()
                controller.setNeedsUpdateOfHomeIndicatorAutoHidden()
            }
    }

    private static func requestGeometryUpdate(
        to orientations: UIInterfaceOrientationMask,
        in scenes: [UIWindowScene],
        onError: (@MainActor (Error) -> Void)? = nil
    ) {
        scenes.forEach { scene in
            scene.requestGeometryUpdate(
                UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientations)
            ) { error in
                guard let onError else { return }
                Task { @MainActor in
                    onError(error)
                }
            }
        }
    }
}

private extension UIWindow {
    var participatesInAppOrientationChrome: Bool {
        !isHidden
            && alpha > 0
            && !(self is PlayerHostWindow)
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UIWindow.appearance().backgroundColor = LaunchAppearance.backgroundColor
        return true
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PlayerSystemMediaControls.clear()
        LaunchAppearance.applyToConnectedWindows()
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        ActivePlaybackCoordinator.shared.stopActivePlayback()
        PlayerSystemMediaControls.clear()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        ActivePlaybackCoordinator.shared.pauseActivePlaybackForAppBackground()
    }

    func applicationProtectedDataWillBecomeUnavailable(_ application: UIApplication) {
        ActivePlaybackCoordinator.shared.pauseActivePlaybackForAppBackground()
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        return AppOrientationLock.supportedOrientations
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        RemoteImageDisplayMemoryCache.shared.clear()
        BiliEmoteMemoryCache.clear()
        // 第 16 轮：警告后暂停首页预取 30 秒（封面预取 + 播放预载），
        // 见 HomeFeedPreloadMemoryWarningPause；暂停期过了自动恢复。
        HomeFeedPreloadMemoryWarningPause.shared.pause()
        Task {
            // 第 16 轮：分级清理——只清已解码的图片缓存，不取消在途下载。
            // 原来 cancelInFlight: true 会连正在下载的封面一起取消，清完又要
            // 重下（RemoteImageCache.finish 只在在途条目还在时才把图写入缓存，
            // 取消后可见 cell 的封面必然重下，加重“清完又下满”的正反馈）。
            // 解码缓存（内存大头）照常清；在途下载留着，完成即入缓存。
            await RemoteImageCache.shared.clearMemoryCache(cancelInFlight: false)
            await PlayURLCache.shared.clearMemoryCache()
            await DanmakuResourceCache.shared.clear()
            // 第 16 轮：警告后暂停图片预取 30 秒（RemoteImageLoadSuppressionGate
            // 的内存警告作用域），避免刚清完又被首页预取立刻下满。
            // 只拦预取（waitUntilAllowed 的 .prefetch 分支），可见图片的加载不受影响。
            await RemoteImageLoadSuppressionGate.shared.suspendPrefetchForMemoryWarning()
        }
    }
}

@MainActor
enum LaunchAppearance {
    static let backgroundColor = UIColor(named: "CiliciliDynamicLaunchBackground") ?? UIColor { traitCollection in
        UIColor.systemBackground.resolvedColor(with: traitCollection)
    }

    static func apply(to window: UIWindow?) {
        guard let window else { return }
        window.backgroundColor = backgroundColor
    }

    static func applyToConnectedWindows() {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .forEach(apply(to:))
    }
}
