import Flutter
import UIKit

/// Official iPhone recipe-book dock as `UITabBarController.bottomAccessory`.
///
/// WWDC25: the accessory sits above the tab bar, then animates down inline
/// when `tabBarMinimizeBehavior = .onScrollDown`. Do not pin this as a
/// sibling overlay — that bypasses the system minimize layout.
final class IosLiquidGlassRecipeBookPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    IosLiquidGlassRecipeBookOverlay.shared.attach(
      messenger: registrar.messenger()
    )
  }
}

final class IosRecipeBookAccessoryHost: UIView {
  let button = UIButton(type: .custom)

  override init(frame: CGRect) {
    super.init(frame: frame)
    // 시스템 accessory가 프레임으로 슬롯을 잡는다. 우리가 나중에 pin하면 워딩이 미끄러진다.
    autoresizingMask = [.flexibleWidth, .flexibleHeight]
    insetsLayoutMarginsFromSafeArea = false
    isUserInteractionEnabled = true
    button.translatesAutoresizingMaskIntoConstraints = false
    button.setContentHuggingPriority(.defaultLow, for: .horizontal)
    button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    addSubview(button)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.trailingAnchor.constraint(equalTo: trailingAnchor),
      button.topAnchor.constraint(equalTo: topAnchor),
      button.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override func didMoveToSuperview() {
    super.didMoveToSuperview()
    guard let slot = superview else { return }
    frame = slot.bounds
    autoresizingMask = [.flexibleWidth, .flexibleHeight]
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: 50)
  }
}

final class IosLiquidGlassRecipeBookOverlay: NSObject, UIGestureRecognizerDelegate {
  static let shared = IosLiquidGlassRecipeBookOverlay()

  private var channel: FlutterMethodChannel?
  private let host = IosRecipeBookAccessoryHost()
  private var button: UIButton { host.button }
  private var installed = false
  private var showRetryCount = 0
  private var lastPanY: CGFloat = 0
  private var dragging = false
  private var savedCount = 0
  private var appliedCount = -1
  private var appliedConfig = false

  func attach(messenger: FlutterBinaryMessenger) {
    let methodChannel = FlutterMethodChannel(
      name: "yorigo.app/ios_liquid_glass_recipe_book",
      binaryMessenger: messenger
    )
    channel = methodChannel
    methodChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "show":
        let args = call.arguments as? [String: Any]
        let supported = self.show(
          savedCount: (args?["savedCount"] as? NSNumber)?.intValue ?? 0
        )
        result(["supported": supported])
      case "hide":
        self.hide()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  @discardableResult
  private func show(savedCount: Int) -> Bool {
    guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
    guard #available(iOS 26.0, *) else { return false }
    self.savedCount = max(savedCount, 0)
    guard flutterViewController() != nil else {
      showRetryCount += 1
      if showRetryCount <= 10 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
          _ = self?.show(savedCount: savedCount)
        }
      }
      return true
    }
    showRetryCount = 0
    prepareHostIfNeeded()
    // 접힘 애니메이션 중에는 설정 재적용을 피하고, 숫자만 바뀔 때 갱신한다.
    if !appliedConfig || appliedCount != savedCount {
      applyConfiguration()
    }
    UIView.performWithoutAnimation {
      IosLiquidGlassTabBarOverlay.shared.setRecipeBookAccessory(
        host,
        animated: false
      )
    }
    IosLiquidGlassTabBarOverlay.shared.bringToFront()
    return true
  }

  private func hide() {
    dragging = false
    IosLiquidGlassTabBarOverlay.shared.setRecipeBookAccessory(
      nil,
      animated: true
    )
  }

  private func prepareHostIfNeeded() {
    if installed { return }
    button.isUserInteractionEnabled = true
    button.addAction(
      UIAction { [weak self] _ in
        self?.emitTap()
      },
      for: .touchUpInside
    )
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    tap.cancelsTouchesInView = false
    host.addGestureRecognizer(tap)
    let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    pan.cancelsTouchesInView = false
    pan.delegate = self
    host.addGestureRecognizer(pan)
    installed = true
  }

  /// Accessory chrome is the tab bar's glass. Content is icon + title + count.
  private func applyConfiguration() {
    var config = UIButton.Configuration.plain()
    config.baseForegroundColor = .label
    config.baseBackgroundColor = .clear
    config.image = recipeBookIcon(pointSize: 28)
    config.imagePadding = 10
    config.imagePlacement = .leading
    config.contentInsets = NSDirectionalEdgeInsets(
      top: 10,
      leading: 16,
      bottom: 10,
      trailing: 16
    )
    config.subtitle = nil
    config.title = nil
    config.attributedTitle = collapsedTitle(count: savedCount)
    config.titleAlignment = .center
    button.configuration = config
    button.contentHorizontalAlignment = .center
    appliedCount = savedCount
    appliedConfig = true
  }

  /// `나의 레시피북 · 12` — 주황 알약 숫자는 첨부 이미지.
  private func collapsedTitle(count: Int) -> AttributedString {
    let font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    var title = AttributedString("나의 레시피북")
    title.font = font
    title.foregroundColor = .label

    var dot = AttributedString("  ·  ")
    dot.font = font
    dot.foregroundColor = .label
    title.append(dot)

    let badge = countBadgeImage(count: count)
    let attachment = NSTextAttachment()
    attachment.image = badge
    let cap = font.capHeight
    attachment.bounds = CGRect(
      x: 0,
      y: (cap - badge.size.height) / 2,
      width: badge.size.width,
      height: badge.size.height
    )
    title.append(AttributedString(NSAttributedString(attachment: attachment)))
    return title
  }

  private func countBadgeImage(count: Int) -> UIImage {
    let text = "\(max(count, 0))"
    let font = UIFont.systemFont(ofSize: 12, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: UIColor.white,
    ]
    let textSize = (text as NSString).size(withAttributes: attrs)
    let height: CGFloat = 18
    let width = max(height, ceil(textSize.width) + 12)
    let size = CGSize(width: width, height: height)
    let format = UIGraphicsImageRendererFormat.default()
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    return renderer.image { _ in
      UIColor(red: 1, green: 105.0 / 255.0, blue: 0, alpha: 1).setFill()
      UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: height / 2).fill()
      let textRect = CGRect(
        x: (width - textSize.width) / 2,
        y: (height - textSize.height) / 2,
        width: textSize.width,
        height: textSize.height
      )
      (text as NSString).draw(in: textRect, withAttributes: attrs)
    }
  }

  @objc private func handleTap() {
    emitTap()
  }

  private func emitTap() {
    guard !dragging else { return }
    channel?.invokeMethod("onTap", arguments: nil)
  }

  @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
    let y = gesture.translation(in: host).y
    switch gesture.state {
    case .began:
      if abs(y) < 8 { return }
      dragging = true
      lastPanY = 0
      channel?.invokeMethod("onDragStart", arguments: nil)
    case .changed:
      guard dragging else {
        if abs(y) >= 8 {
          dragging = true
          lastPanY = y
          channel?.invokeMethod("onDragStart", arguments: nil)
        }
        return
      }
      let delta = y - lastPanY
      lastPanY = y
      channel?.invokeMethod("onDragUpdate", arguments: delta)
    case .ended:
      guard dragging else { return }
      dragging = false
      lastPanY = 0
      let velocity = gesture.velocity(in: host).y
      channel?.invokeMethod("onDragEnd", arguments: velocity)
    default:
      if dragging {
        dragging = false
        lastPanY = 0
        channel?.invokeMethod("onDragCancel", arguments: nil)
      }
    }
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool {
    true
  }

  /// 홈 도크와 같은 `recipebook_3d_icon.png`. 컬러를 유지한다.
  private func recipeBookIcon(pointSize: CGFloat) -> UIImage? {
    let key = FlutterDartProject.lookupKey(forAsset: "assets/images/recipebook_3d_icon.png")
    let path = (Bundle.main.bundlePath as NSString).appendingPathComponent(key)
    guard let source = UIImage(contentsOfFile: path) else {
      return UIImage(systemName: "book.fill")
    }
    let format = UIGraphicsImageRendererFormat.default()
    format.opaque = false
    let size = CGSize(width: pointSize, height: pointSize)
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    let drawn = renderer.image { _ in
      source.draw(in: CGRect(origin: .zero, size: size))
    }
    return drawn.withRenderingMode(.alwaysOriginal)
  }

  private func flutterViewController() -> FlutterViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
    let window = windows.first(where: \.isKeyWindow) ?? windows.first
    if let flutter = window?.rootViewController as? FlutterViewController {
      return flutter
    }
    return topViewController(from: window?.rootViewController) as? FlutterViewController
  }

  private func topViewController(from root: UIViewController?) -> UIViewController? {
    if let presented = root?.presentedViewController {
      return topViewController(from: presented)
    }
    if let nav = root as? UINavigationController {
      return topViewController(from: nav.visibleViewController)
    }
    if let tab = root as? UITabBarController {
      return topViewController(from: tab.selectedViewController)
    }
    return root
  }
}
