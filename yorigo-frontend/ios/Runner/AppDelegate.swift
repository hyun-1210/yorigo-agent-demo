import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var sharedText: String?
  private let CHANNEL = "yorigo.app/share"
  private var shareChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    configureAudioSessionForVideoPlayback()

    if let registrar = self.registrar(forPlugin: "IosLiquidGlassTabBarPlugin") {
      IosLiquidGlassTabBarPlugin.register(with: registrar)
    }
    if let registrar = self.registrar(forPlugin: "IosLiquidGlassRecipeBookPlugin") {
      IosLiquidGlassRecipeBookPlugin.register(with: registrar)
    }
    if let registrar = self.registrar(forPlugin: "IosActionSheetPlugin") {
      IosActionSheetPlugin.register(with: registrar)
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      if let controller = self.window?.rootViewController as? FlutterViewController {
        self.setupMethodChannel(controller: controller)
        CoupangCommissionBrowserPlugin.register(with: controller.binaryMessenger)

        if let sharedUrl = self.consumeSharedUrl(
          schemeUrl: launchOptions?[.url] as? URL
        ) {
          print("[AppDelegate] Found shared URL on launch: \(sharedUrl)")
          DispatchQueue.main.async {
            self.handleSharedContent(sharedUrl)
          }
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    if shareChannel == nil, let controller = window?.rootViewController as? FlutterViewController {
      setupMethodChannel(controller: controller)
      CoupangCommissionBrowserPlugin.register(with: controller.binaryMessenger)
    }

    if let sharedUrl = consumeSharedUrl() {
      print("[AppDelegate] Found shared URL when app became active: \(sharedUrl)")
      handleSharedContent(sharedUrl)
    }
  }

  /// 카테고리만 지정. launch 중 setActive(true) 는 WebView/오디오 플러그인과 경합한다.
  private func configureAudioSessionForVideoPlayback() {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .playback,
        mode: .moviePlayback,
        options: [.mixWithOthers]
      )
    } catch {
      print("[AppDelegate] AVAudioSession setup failed: \(error)")
    }
  }

  private func setupMethodChannel(controller: FlutterViewController) {
    shareChannel = FlutterMethodChannel(
      name: CHANNEL,
      binaryMessenger: controller.binaryMessenger
    )

    shareChannel?.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      if call.method == "getInitialSharedText" {
        // Flutter 핸들러가 붙기 전에 invoke가 떨어지면 유실된다.
        // getInitialSharedText가 소비할 때까지 메모리에 남겨 둔다.
        result(self?.sharedText)
        self?.sharedText = nil
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    if let text = sharedText {
      shareChannel?.invokeMethod("sharedText", arguments: text)
    }
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    if let scheme = url.scheme,
       scheme.hasPrefix("com.googleusercontent.apps") {
      return super.application(app, open: url, options: options)
    }
    if url.scheme == "yorigo" && url.host == "share" {
      print("[AppDelegate] Received yorigo://share URL scheme")
      if let sharedUrl = consumeSharedUrl(schemeUrl: url) {
        print("[AppDelegate] Found shared URL: \(sharedUrl)")
        DispatchQueue.main.async {
          self.handleSharedContent(sharedUrl)
        }
      } else {
        print("[AppDelegate] No shared URL found in UserDefaults or scheme")
      }
      return true
    }
    if super.application(app, open: url, options: options) {
      return true
    }
    if let scheme = url.scheme, scheme.hasPrefix("kakao") {
      return true
    }
    handleSharedContent(url.absoluteString)
    return true
  }

  override func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
       let url = userActivity.webpageURL {
      let host = (url.host ?? "").lowercased()
      if host.contains("kakao") || host == "talk-apps.kakao.com" {
        return super.application(
          application,
          continue: userActivity,
          restorationHandler: restorationHandler
        )
      }
      handleSharedContent(url.absoluteString)
      return true
    }
    return super.application(
      application,
      continue: userActivity,
      restorationHandler: restorationHandler
    )
  }

  /// App Group 값을 우선하고, 없으면 `yorigo://share?url=` 쿼리를 쓴다.
  private func consumeSharedUrl(schemeUrl: URL? = nil) -> String? {
    let appGroupId = "group.com.yorigo.kr.shared"
    if let sharedDefaults = UserDefaults(suiteName: appGroupId),
       let sharedUrl = sharedDefaults.string(forKey: "sharedUrl"),
       !sharedUrl.isEmpty {
      sharedDefaults.removeObject(forKey: "sharedUrl")
      sharedDefaults.synchronize()
      return sharedUrl
    }
    if let schemeUrl,
       let item = URLComponents(url: schemeUrl, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first(where: { $0.name == "url" })?
        .value,
       !item.isEmpty {
      return item
    }
    return nil
  }

  private func handleSharedContent(_ text: String) {
    print("[AppDelegate] Handling shared content: \(text)")
    sharedText = text

    if shareChannel == nil {
      if let controller = window?.rootViewController as? FlutterViewController {
        setupMethodChannel(controller: controller)
        return
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        if let controller = self.window?.rootViewController as? FlutterViewController {
          self.setupMethodChannel(controller: controller)
          self.shareChannel?.invokeMethod("sharedText", arguments: text)
        }
      }
      return
    }

    shareChannel?.invokeMethod("sharedText", arguments: text)
    print("[AppDelegate] Sent shared text to Flutter via method channel")
  }
}
