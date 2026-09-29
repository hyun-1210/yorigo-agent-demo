import Flutter
import UIKit
import WebKit

/// Presents Coupang affiliate links in a native in-app browser with reliable auto-close.
///
/// Flutter cannot observe SFSafariViewController URL changes or the universal-link dialog.
/// This controller uses WKWebView plus native lifecycle hooks:
/// - **Open in Coupang**: app backgrounds → dismiss when user returns.
/// - **Cancel**: after the dialog window, a short dwell on the product page → dismiss.
/// - **Done**: user taps the toolbar button.
final class CoupangCommissionBrowserController: UIViewController {
  enum CloseReason: String {
    case userDismissed
    case openedNativeApp
    case stayedOnWeb
    case returnedFromExternalApp
  }

  private enum Phase {
    case loadingAffiliate
    case dialogEligible
    case closing
  }

  private let initialUrl: URL
  private var flutterResult: FlutterResult?
  private var webView: WKWebView!
  private var phase: Phase = .loadingAffiliate
  private let presentedAt = Date()
  private var affiliateFinishedAt: Date?
  private var armDialogWorkItem: DispatchWorkItem?
  private var stayOnWebWorkItem: DispatchWorkItem?
  private var sawExternalApp = false
  private var lifecycleObservers: [NSObjectProtocol] = []

  init(url: URL, result: @escaping FlutterResult) {
    initialUrl = url
    flutterResult = result
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    removeLifecycleObservers()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    configureWebView()
    configureToolbar()
    registerLifecycleObservers()
    webView.load(URLRequest(url: initialUrl))
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    removeLifecycleObservers()
  }

  private func configureWebView() {
    let config = WKWebViewConfiguration()
    if #available(iOS 14.0, *) {
      config.defaultWebpagePreferences.allowsContentJavaScript = true
    } else {
      config.preferences.javaScriptEnabled = true
    }

    webView = WKWebView(frame: .zero, configuration: config)
    webView.translatesAutoresizingMaskIntoConstraints = false
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.customUserAgent =
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
      + "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    view.addSubview(webView)
    NSLayoutConstraint.activate([
      webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  private func configureToolbar() {
    let toolbar = UIToolbar()
    toolbar.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(toolbar)

    let done = UIBarButtonItem(
      barButtonSystemItem: .done,
      target: self,
      action: #selector(doneTapped)
    )
    toolbar.items = [
      UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
      done,
    ]

    NSLayoutConstraint.activate([
      toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
    ])
  }

  @objc private func doneTapped() {
    finish(reason: .userDismissed)
  }

  private func registerLifecycleObservers() {
    let center = NotificationCenter.default
    lifecycleObservers.append(
      center.addObserver(
        forName: UIApplication.willResignActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.handleWillResignActive()
      }
    )
    lifecycleObservers.append(
      center.addObserver(
        forName: UIApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.handleDidBecomeActive()
      }
    )
  }

  private func removeLifecycleObservers() {
    let center = NotificationCenter.default
    lifecycleObservers.forEach { center.removeObserver($0) }
    lifecycleObservers.removeAll()
  }

  private func handleWillResignActive() {
    guard phase != .closing else { return }
    cancelStayOnWebClose()
    guard phase == .dialogEligible else { return }
    sawExternalApp = true
    finish(reason: .openedNativeApp)
  }

  private func handleDidBecomeActive() {
    // Browser already dismissed in handleWillResignActive when opening Coupang.
  }

  private static func isAffiliateHost(_ url: URL) -> Bool {
    url.host?.lowercased() == "link.coupang.com"
  }

  private static func isProductHost(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
      return false
    }
    let host = url.host?.lowercased() ?? ""
    if host == "link.coupang.com" { return false }
    return host == "coupang.com" || host.hasSuffix(".coupang.com")
  }

  private static func isNativeScheme(_ url: URL) -> Bool {
    url.scheme?.lowercased() == "coupang"
  }

  private func noteAffiliateFinished() {
    if affiliateFinishedAt == nil {
      affiliateFinishedAt = Date()
    }
    scheduleDialogEligibility()
  }

  /// Wait until the affiliate page is stable and the user had time for the system dialog.
  private func scheduleDialogEligibility() {
    armDialogWorkItem?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.armDialogEligibleIfReady()
    }
    armDialogWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
  }

  private func armDialogEligibleIfReady() {
    guard phase == .loadingAffiliate else { return }

    let minPresentationInterval: TimeInterval = 2.5
    let sincePresent = Date().timeIntervalSince(presentedAt)
    if sincePresent < minPresentationInterval {
      let remaining = minPresentationInterval - sincePresent
      armDialogWorkItem?.cancel()
      let work = DispatchWorkItem { [weak self] in
        self?.armDialogEligibleIfReady()
      }
      armDialogWorkItem = work
      DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
      return
    }

    phase = .dialogEligible
    if let url = webView.url, Self.isProductHost(url) {
      scheduleStayOnWebClose()
    }
  }

  private func cancelStayOnWebClose() {
    stayOnWebWorkItem?.cancel()
    stayOnWebWorkItem = nil
  }

  /// User likely tapped "Cancel" and stayed on the Coupang web product page.
  private func scheduleStayOnWebClose() {
    guard phase == .dialogEligible, !sawExternalApp else { return }
    cancelStayOnWebClose()
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.phase == .dialogEligible, !self.sawExternalApp else { return }
      self.finish(reason: .stayedOnWeb)
    }
    stayOnWebWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
  }

  private func handleNativeAppLink(_ url: URL) {
    guard phase != .closing else { return }
    UIApplication.shared.open(url, options: [:], completionHandler: nil)
    finish(reason: .openedNativeApp)
  }

  private func finish(reason: CloseReason) {
    guard phase != .closing else { return }
    phase = .closing
    cancelStayOnWebClose()
    armDialogWorkItem?.cancel()

    dismiss(animated: true) { [weak self] in
      guard let self else { return }
      self.flutterResult?(["reason": reason.rawValue])
      self.flutterResult = nil
    }
  }
}

extension CoupangCommissionBrowserController: WKNavigationDelegate {
  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.allow)
      return
    }

    if Self.isNativeScheme(url) {
      handleNativeAppLink(url)
      decisionHandler(.cancel)
      return
    }

    if phase == .dialogEligible, Self.isProductHost(url) {
      scheduleStayOnWebClose()
    }

    decisionHandler(.allow)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    guard let url = webView.url else { return }

    if Self.isAffiliateHost(url) {
      noteAffiliateFinished()
      return
    }

    if phase == .loadingAffiliate, Self.isProductHost(url) {
      // Early redirect before affiliate didFinish — still wait for dialog eligibility.
      noteAffiliateFinished()
      return
    }

    if phase == .dialogEligible, Self.isProductHost(url) {
      scheduleStayOnWebClose()
    }
  }
}

extension CoupangCommissionBrowserController: WKUIDelegate {
  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    if let url = navigationAction.request.url {
      webView.load(URLRequest(url: url))
    }
    return nil
  }
}

enum CoupangCommissionBrowserPlugin {
  private static let channelName = "yorigo.app/marketplace"
  private static var channel: FlutterMethodChannel?
  private static weak var activeController: CoupangCommissionBrowserController?

  static func register(with messenger: FlutterBinaryMessenger) {
    let methodChannel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: messenger
    )
    channel = methodChannel

    methodChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "openCoupangCommissionLink":
        guard let args = call.arguments as? [String: Any],
              let urlString = args["url"] as? String,
              let url = URL(string: urlString)
        else {
          result(
            FlutterError(
              code: "invalid_args",
              message: "url is required",
              details: nil
            )
          )
          return
        }
        guard let host = flutterViewController() else {
          result(
            FlutterError(
              code: "no_host",
              message: "Flutter view is not ready",
              details: nil
            )
          )
          return
        }
        present(from: host, url: url, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func flutterViewController() -> FlutterViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
    let window = windows.first(where: \.isKeyWindow) ?? windows.first
    return window?.rootViewController as? FlutterViewController
  }

  private static func present(
    from flutterController: FlutterViewController,
    url: URL,
    result: @escaping FlutterResult
  ) {
    DispatchQueue.main.async {
      if let activeController {
        activeController.dismiss(animated: false)
      }

      let browser = CoupangCommissionBrowserController(url: url, result: result)
      activeController = browser
      flutterController.present(browser, animated: true)
    }
  }
}
