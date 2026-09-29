import Flutter
import UIKit

/// Native iPhone tab bar as a **window overlay**, not a Flutter `UiKitView`.
///
/// WWDC25: `tabBarMinimizeBehavior` + `bottomAccessory` require a real
/// `UIScrollView` receiving the user's vertical pan. Flutter lists are not
/// UIScrollViews, so on the home tab the drive scroll view sits in the hit
/// path and takes **vertical** pans only (so the tab bar can minimize).
/// Taps and horizontal rails go to FlutterViewController's pointer dispatch.
final class IosLiquidGlassTabBarPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    IosLiquidGlassTabBarOverlay.shared.attach(
      messenger: registrar.messenger()
    )
  }
}

/// Hits tab chrome, or the home drive scroll. Everything else falls to Flutter.
final class IosChromePassthroughView: UIView {
  weak var tabController: UITabBarController?
  weak var homeDriveScroll: UIScrollView?
  /// 레시피북 페이지 등에서 크롬이 내려가는 즉시 히트를 끊는다.
  /// 커스텀 hitTest는 isHidden/isUserInteractionEnabled를 자동으로 보지 않는다.
  var chromeHitsEnabled = true

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard chromeHitsEnabled, !isHidden, isUserInteractionEnabled, alpha > 0.01 else {
      return nil
    }
    guard let tab = tabController, !tab.view.isHidden else { return nil }
    let accessory = tab.bottomAccessoryContentView
    let inline = isMinimizedDock(accessory: accessory, tabBar: tab.tabBar)

    if inline {
      // 접힘: 5개 탭 버튼이 히트트리에 그대로 남아 알약 자리를
      // 장바구니/냉장고가 먹는다. 알약 → 왼쪽 홈 원만 허용.
      if let accessory,
         let recipeHit = hitRecipeBook(
           point,
           accessory: accessory,
           event: event,
           inline: true
         ) {
        return recipeHit
      }
      if let homeHit = hitMinimizedHomeControl(
        point,
        tabBar: tab.tabBar,
        event: event
      ) {
        return homeHit
      }
    } else {
      if let accessory,
         let recipeHit = hitRecipeBook(
           point,
           accessory: accessory,
           event: event,
           inline: false
         ) {
        return recipeHit
      }
      if let barControl = hitTabBarControl(point, tabBar: tab.tabBar, event: event) {
        return barControl
      }
      if let barHit = hitVisibleTabBar(point, tabBar: tab.tabBar, event: event) {
        return barHit
      }
    }

    if tab.selectedIndex == 0, let scroll = homeDriveScroll, !scroll.isHidden {
      let inScroll = convert(point, to: scroll)
      if scroll.bounds.contains(inScroll) {
        return scroll
      }
    }
    return nil
  }

  private static func isInlineAccessory(_ accessory: UIView?) -> Bool {
    guard #available(iOS 26.0, *), let accessory else { return false }
    return accessory.traitCollection.tabAccessoryEnvironment == .inline
  }

  /// 시스템 trait가 늦어도, 알약이 홈 원 오른쪽에 있으면 접힌 도크로 본다.
  private func isMinimizedDock(accessory: UIView?, tabBar: UITabBar) -> Bool {
    if Self.isInlineAccessory(accessory) { return true }
    guard let accessory else { return false }
    let acc = accessory.convert(accessory.bounds, to: self)
    guard acc.height > 20, acc.height < 180 else { return false }
    guard acc.maxY > bounds.height - 180 else { return false }
    return acc.minX > 40
  }

  /// `UITabBarButton`만 히트. 펼친 탭바에서 사용.
  private func hitTabBarControl(
    _ point: CGPoint,
    tabBar: UITabBar,
    event: UIEvent?
  ) -> UIView? {
    for button in tabBarButtons(in: tabBar) {
      let rect = button.convert(button.bounds, to: self)
      guard rect.contains(point) else { continue }
      let inBar = convert(point, to: tabBar)
      return tabBar.hitTest(inBar, with: event) ?? button
    }
    return nil
  }

  /// 접힌 홈 원만. 가로로 펼쳐진 고스트 탭(장바구니·냉장고)은 무시한다.
  private func hitMinimizedHomeControl(
    _ point: CGPoint,
    tabBar: UITabBar,
    event: UIEvent?
  ) -> UIView? {
    for button in tabBarButtons(in: tabBar) {
      let rect = button.convert(button.bounds, to: self)
      guard rect.contains(point) else { continue }
      guard rect.minX < bounds.minX + 96 else { continue }
      guard rect.width <= 108, rect.height <= 108 else { continue }
      let inBar = convert(point, to: tabBar)
      return tabBar.hitTest(inBar, with: event) ?? button
    }
    return nil
  }

  private func tabBarButtons(in root: UIView) -> [UIView] {
    let accessory = tabController?.bottomAccessoryContentView
    var buttons: [UIView] = []
    func walk(_ view: UIView) {
      if let accessory, view === accessory || view.isDescendant(of: accessory) {
        return
      }
      let typeName = String(describing: type(of: view))
      if typeName.contains("TabBarButton") || (view is UIControl && typeName.contains("Tab")) {
        buttons.append(view)
      }
      for child in view.subviews {
        walk(child)
      }
    }
    walk(root)
    return buttons
  }

  /// accessory 자신의 알약만 히트. 접힌 슬롯의 부모 뷰는 홈 원까지 포함한다.
  private func hitRecipeBook(
    _ point: CGPoint,
    accessory: UIView,
    event: UIEvent?,
    inline: Bool
  ) -> UIView? {
    let rect = accessory.convert(accessory.bounds, to: self)
    guard rect.width > 24, rect.height > 20 else { return nil }
    guard rect.height < 180 else { return nil }
    guard rect.contains(point) else { return nil }
    if inline, point.x < bounds.minX + 92 {
      return nil
    }
    if !inline, let bar = tabController?.tabBar {
      for button in tabBarButtons(in: bar) {
        let buttonRect = button.convert(button.bounds, to: self)
        if buttonRect.contains(point) { return nil }
      }
    }
    let inAccessory = convert(point, to: accessory)
    return accessory.hitTest(inAccessory, with: event) ?? accessory
  }

  /// 플로팅 탭바의 실제 하단 띠만 히트. full-screen tabBar.bounds는 쓰지 않는다.
  private func hitVisibleTabBar(
    _ point: CGPoint,
    tabBar: UITabBar,
    event: UIEvent?
  ) -> UIView? {
    let barRect = tabBar.convert(tabBar.bounds, to: self)
    let visual: CGRect
    if barRect.height > 140 {
      visual = CGRect(
        x: barRect.minX,
        y: barRect.maxY - 100,
        width: barRect.width,
        height: 100
      )
    } else {
      visual = barRect
    }
    guard visual.contains(point) else { return nil }
    let inBar = convert(point, to: tabBar)
    return tabBar.hitTest(inBar, with: event) ?? tabBar
  }
}

private extension UITabBarController {
  var bottomAccessoryContentView: UIView? {
    if #available(iOS 26.0, *) {
      return bottomAccessory?.contentView
    }
    return nil
  }
}

/// 공식 contentScrollView. 세로 팬만 가져가서 minimize를 살리고,
/// 탭/가로 레일은 FlutterViewController로 포인터를 직접 넣는다.
final class IosDriveScrollView: UIScrollView {
  weak var flutterViewController: FlutterViewController?

  override func didMoveToWindow() {
    super.didMoveToWindow()
    // 탭이 pan 실패를 기다리지 않게. 세로 스크롤 pan 자체는 그대로다.
    panGestureRecognizer.delaysTouchesBegan = false
    panGestureRecognizer.delaysTouchesEnded = false
  }

  /// 가로 제스처는 스크롤뷰 pan이 먹으면 Flutter 레일/탭이 죽는다.
  override func gestureRecognizerShouldBegin(
    _ gestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    if gestureRecognizer === panGestureRecognizer {
      let translation = panGestureRecognizer.translation(in: self)
      let velocity = panGestureRecognizer.velocity(in: self)
      let dx = max(abs(translation.x), abs(velocity.x) * 0.016)
      let dy = max(abs(translation.y), abs(velocity.y) * 0.016)
      if dy > dx { return true }
      if dx > dy { return false }
      return abs(velocity.y) >= abs(velocity.x)
    }
    return super.gestureRecognizerShouldBegin(gestureRecognizer)
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    flutterViewController?.touchesBegan(touches, with: event)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    flutterViewController?.touchesMoved(touches, with: event)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    flutterViewController?.touchesEnded(touches, with: event)
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    flutterViewController?.touchesCancelled(touches, with: event)
  }
}

final class IosHomeTabDriveController: UIViewController, UIScrollViewDelegate {
  let driveScroll = IosDriveScrollView()
  var onOffset: ((CGFloat, CGFloat) -> Void)?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    view.isOpaque = false
    driveScroll.backgroundColor = .clear
    driveScroll.isOpaque = false
    driveScroll.delegate = self
    driveScroll.alwaysBounceVertical = true
    driveScroll.showsVerticalScrollIndicator = false
    driveScroll.showsHorizontalScrollIndicator = false
    driveScroll.contentInsetAdjustmentBehavior = .never
    driveScroll.delaysContentTouches = false
    driveScroll.canCancelContentTouches = false
    driveScroll.alwaysBounceHorizontal = false
    driveScroll.isDirectionalLockEnabled = true
    driveScroll.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(driveScroll)
    NSLayoutConstraint.activate([
      driveScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      driveScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      driveScroll.topAnchor.constraint(equalTo: view.topAnchor),
      driveScroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    driveScroll.contentSize = CGSize(width: 1, height: 2400)
    setContentScrollView(driveScroll)
    setContentScrollView(driveScroll, for: .bottom)
  }

  override func contentScrollView(for edge: NSDirectionalRectEdge) -> UIScrollView? {
    if edge.contains(.bottom) || edge.contains(.top) { return driveScroll }
    return super.contentScrollView(for: edge)
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    let maxExtent = max(scrollView.contentSize.height - scrollView.bounds.height, 0)
    onOffset?(scrollView.contentOffset.y, maxExtent)
  }
}

final class IosLiquidGlassTabBarOverlay: NSObject, UITabBarControllerDelegate {
  static let shared = IosLiquidGlassTabBarOverlay()

  private let tabController = UITabBarController()
  private let passthrough = IosChromePassthroughView()
  private var homeDrive: IosHomeTabDriveController?
  private var channel: FlutterMethodChannel?
  private var installed = false
  private var showRetryCount = 0
  private var pendingRecipeBookView: UIView?
  private var publishingOffset = false
  private var chromeAnimationToken = 0
  /// Flutter 모달(레시피 추가 시트 등)이 열려 있으면 크롬은 보이되 히트만 끈다.
  private var flutterHitsEnabled = true
  /// 시스템 onScrollDown은 맨 위에서만 다시 펼친다. 위로 스크롤하면 .never로 펼친다.
  private var lastDriveOffset: CGFloat = 0
  private static let chromeHideOffset: CGFloat = 160

  func attach(messenger: FlutterBinaryMessenger) {
    let methodChannel = FlutterMethodChannel(
      name: "yorigo.app/ios_liquid_glass_tab_bar",
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
        self.show(
          selectedIndex: (args?["selectedIndex"] as? NSNumber)?.intValue ?? 0,
          cartBadge: (args?["cartBadge"] as? NSNumber)?.intValue ?? 0,
          animated: (args?["animated"] as? Bool) ?? false
        )
        result(nil)
      case "hide":
        let args = call.arguments as? [String: Any]
        self.hide(animated: (args?["animated"] as? Bool) ?? false)
        result(nil)
      case "setSelectedIndex":
        if let index = call.arguments as? Int {
          self.setSelectedIndex(index)
        }
        result(nil)
      case "setCartBadge":
        self.applyCartBadge((call.arguments as? Int) ?? 0)
        result(nil)
      case "setHomeScrollOffset":
        let args = call.arguments as? [String: Any]
        self.setHomeScrollMetrics(
          offset: CGFloat((args?["offset"] as? NSNumber)?.doubleValue ?? 0),
          maxExtent: CGFloat((args?["maxExtent"] as? NSNumber)?.doubleValue ?? 0),
          applyOffset: false
        )
        result(nil)
      case "setHitsEnabled":
        let enabled: Bool
        if let flag = call.arguments as? Bool {
          enabled = flag
        } else if let number = call.arguments as? NSNumber {
          enabled = number.boolValue
        } else {
          enabled = true
        }
        self.flutterHitsEnabled = enabled
        if !self.passthrough.isHidden {
          self.passthrough.chromeHitsEnabled = enabled
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func show(selectedIndex: Int, cartBadge: Int, animated: Bool = false) {
    guard UIDevice.current.userInterfaceIdiom == .phone else { return }
    guard let host = flutterViewController() else {
      showRetryCount += 1
      if showRetryCount <= 10 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
          self?.show(
            selectedIndex: selectedIndex,
            cartBadge: cartBadge,
            animated: animated
          )
        }
      }
      return
    }
    showRetryCount = 0
    installIfNeeded(in: host)
    homeDrive?.driveScroll.flutterViewController = host
    setSelectedIndex(selectedIndex)
    applyCartBadge(cartBadge)
    let alreadyVisible = !passthrough.isHidden
      && !tabController.view.isHidden
      && passthrough.alpha > 0.99
      && passthrough.transform == .identity
    chromeAnimationToken += 1
    passthrough.chromeHitsEnabled = flutterHitsEnabled
    passthrough.isHidden = false
    tabController.view.isHidden = false
    passthrough.isUserInteractionEnabled = true
    if animated && !alreadyVisible {
      if passthrough.alpha >= 0.99 {
        passthrough.alpha = 0
        passthrough.transform = CGAffineTransform(
          translationX: 0,
          y: Self.chromeHideOffset
        )
      }
      UIView.animate(
        withDuration: 0.42,
        delay: 0.12,
        options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
      ) {
        self.passthrough.alpha = 1
        self.passthrough.transform = .identity
      }
    } else {
      passthrough.alpha = 1
      passthrough.transform = .identity
      if !alreadyVisible {
        host.view.bringSubviewToFront(passthrough)
      }
    }
  }

  private func hide(animated: Bool = false) {
    chromeAnimationToken += 1
    let token = chromeAnimationToken
    passthrough.chromeHitsEnabled = false
    passthrough.isUserInteractionEnabled = false
    guard !passthrough.isHidden else { return }
    if !animated {
      passthrough.layer.removeAllAnimations()
      passthrough.isHidden = true
      tabController.view.isHidden = true
      passthrough.alpha = 1
      passthrough.transform = .identity
      return
    }
    passthrough.isHidden = false
    tabController.view.isHidden = false
    UIView.animate(
      withDuration: 0.38,
      delay: 0,
      options: [.curveEaseIn, .beginFromCurrentState]
    ) {
      self.passthrough.alpha = 0
      self.passthrough.transform = CGAffineTransform(
        translationX: 0,
        y: Self.chromeHideOffset
      )
    } completion: { _ in
      guard token == self.chromeAnimationToken else { return }
      self.passthrough.isHidden = true
      self.tabController.view.isHidden = true
      self.passthrough.alpha = 1
      self.passthrough.transform = .identity
    }
  }

  private func installIfNeeded(in host: UIViewController) {
    if installed {
      if tabController.parent !== host {
        tabController.willMove(toParent: nil)
        tabController.view.removeFromSuperview()
        tabController.removeFromParent()
        passthrough.removeFromSuperview()
        installed = false
      } else {
        return
      }
    }

    let titles = ["홈", "커뮤니티", "장바구니", "냉장고", "프로필"]
    let assets = [
      "assets/icons/nav_home.png",
      "assets/icons/nav_community.png",
      "assets/icons/nav_cart.png",
      "assets/icons/nav_fridge.png",
      "assets/icons/nav_profile.png",
    ]
    let fallback = ["house", "text.bubble", "cart", "archivebox", "person"]

    tabController.viewControllers = (0..<titles.count).map { index in
      let vc: UIViewController
      if index == 0 {
        let home = IosHomeTabDriveController()
        home.onOffset = { [weak self] offset, maxExtent in
          self?.updateMinimizeForScroll(offset: offset, maxExtent: maxExtent)
          self?.publishHomeOffset(offset, maxExtent: maxExtent)
        }
        homeDrive = home
        vc = home
      } else {
        vc = UIViewController()
      }
      vc.view.backgroundColor = .clear
      vc.view.isOpaque = false
      vc.view.isUserInteractionEnabled = index == 0
      let icon = flutterAssetTabImage(assets[index])
        ?? UIImage(systemName: fallback[index])
      let item = UITabBarItem(
        title: titles[index],
        image: icon,
        selectedImage: icon
      )
      item.tag = index
      vc.tabBarItem = item
      return vc
    }
    tabController.delegate = self
    tabController.view.backgroundColor = .clear
    tabController.view.isOpaque = false

    let tabBar = tabController.tabBar
    tabBar.tintColor = UIColor(red: 1, green: 107.0 / 255.0, blue: 0, alpha: 1)
    tabBar.unselectedItemTintColor = UIColor(
      red: 153.0 / 255.0,
      green: 161.0 / 255.0,
      blue: 175.0 / 255.0,
      alpha: 1
    )
    tabBar.isTranslucent = true

    if #available(iOS 26.0, *) {
      tabController.tabBarMinimizeBehavior = .onScrollDown
    }

    passthrough.tabController = tabController
    passthrough.homeDriveScroll = homeDrive?.driveScroll
    passthrough.backgroundColor = .clear
    passthrough.isOpaque = false
    passthrough.translatesAutoresizingMaskIntoConstraints = false

    host.addChild(tabController)
    host.view.addSubview(passthrough)
    passthrough.addSubview(tabController.view)
    tabController.view.translatesAutoresizingMaskIntoConstraints = false
    tabController.didMove(toParent: host)

    NSLayoutConstraint.activate([
      passthrough.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
      passthrough.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
      passthrough.topAnchor.constraint(equalTo: host.view.topAnchor),
      passthrough.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
      tabController.view.leadingAnchor.constraint(equalTo: passthrough.leadingAnchor),
      tabController.view.trailingAnchor.constraint(equalTo: passthrough.trailingAnchor),
      tabController.view.topAnchor.constraint(equalTo: passthrough.topAnchor),
      tabController.view.bottomAnchor.constraint(equalTo: passthrough.bottomAnchor),
    ])
    host.view.layoutIfNeeded()
    homeDrive?.view.layoutIfNeeded()
    installed = true
    setRecipeBookAccessory(pendingRecipeBookView, animated: false)
  }

  private func publishHomeOffset(_ offset: CGFloat, maxExtent: CGFloat) {
    if publishingOffset { return }
    channel?.invokeMethod(
      "onHomeScrollOffset",
      arguments: ["offset": offset, "maxExtent": maxExtent]
    )
  }

  /// 내리면 접고, 올리면 바로 5탭으로 되돌린다.
  /// iOS 26의 `.onScrollDown`은 맨 위(offset 0)에서만 다시 펼쳐서 피드 중간에선
  /// 레시피북 알약만 남는다.
  private func updateMinimizeForScroll(offset: CGFloat, maxExtent: CGFloat) {
    guard #available(iOS 26.0, *) else { return }
    if publishingOffset { return }
    let y = min(max(offset, 0), max(maxExtent, 0))

    if y <= 1 {
      lastDriveOffset = y
      if tabController.tabBarMinimizeBehavior != .onScrollDown {
        tabController.tabBarMinimizeBehavior = .onScrollDown
      }
      return
    }

    let velY = homeDrive?.driveScroll.panGestureRecognizer.velocity(
      in: homeDrive?.driveScroll
    ).y ?? 0
    let delta = y - lastDriveOffset
    let goingTowardTop: Bool
    if abs(velY) > 80 {
      goingTowardTop = velY > 0
    } else if abs(delta) > 6 {
      goingTowardTop = delta < 0
    } else {
      return
    }
    lastDriveOffset = y

    let next: UITabBarController.MinimizeBehavior = goingTowardTop
      ? .never
      : .onScrollDown
    if tabController.tabBarMinimizeBehavior != next {
      tabController.tabBarMinimizeBehavior = next
    }
  }

  /// Flutter 레이아웃에서 콘텐츠 높이만 받아 공식 스크롤뷰 contentSize를 맞춘다.
  func setHomeScrollMetrics(offset: CGFloat, maxExtent: CGFloat, applyOffset: Bool) {
    guard let scroll = homeDrive?.driveScroll else { return }
    let tracking = scroll.isTracking || scroll.isDragging || scroll.isDecelerating
    if !tracking {
      homeDrive?.view.layoutIfNeeded()
    }
    let boundsH = max(scroll.bounds.height, UIScreen.main.bounds.height)
    let proposed = max(maxExtent + boundsH + 80, boundsH + 800)
    // 접힌 뒤 contentSize가 줄면 offset이 잘려 시스템이 스크롤 업으로 본다.
    let keepOffset = scroll.contentOffset.y + boundsH + 80
    let contentH = tracking
      ? max(proposed, scroll.contentSize.height, keepOffset)
      : max(proposed, keepOffset)
    if abs(scroll.contentSize.height - contentH) > 1 {
      scroll.contentSize = CGSize(
        width: max(scroll.bounds.width, UIScreen.main.bounds.width),
        height: contentH
      )
    }
    guard applyOffset else { return }
    let maxY = max(scroll.contentSize.height - scroll.bounds.height, 0)
    let y = min(max(offset, 0), maxY)
    if abs(scroll.contentOffset.y - y) > 0.5 {
      publishingOffset = true
      scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
      publishingOffset = false
    }
  }

  /// WWDC25: `UITabAccessory` — 접히면 알약이 탭바 옆으로 내려간다.
  func setRecipeBookAccessory(_ view: UIView?, animated: Bool) {
    pendingRecipeBookView = view
    guard #available(iOS 26.0, *) else { return }
    guard installed else { return }
    if let view {
      if view.superview != nil, tabController.bottomAccessory?.contentView !== view {
        view.removeFromSuperview()
      }
      if tabController.bottomAccessory?.contentView === view { return }
      tabController.setBottomAccessory(
        UITabAccessory(contentView: view),
        animated: animated
      )
    } else {
      if tabController.bottomAccessory == nil { return }
      tabController.setBottomAccessory(nil, animated: animated)
    }
  }

  func bringToFront() {
    guard passthrough.superview != nil else { return }
    passthrough.superview?.bringSubviewToFront(passthrough)
  }

  var chromeTabBar: UITabBar { tabController.tabBar }

  private func setSelectedIndex(_ index: Int) {
    let count = tabController.viewControllers?.count ?? 0
    guard count > 0 else { return }
    let next = min(max(index, 0), count - 1)
    if tabController.selectedIndex != next {
      tabController.selectedIndex = next
    }
    homeDrive?.driveScroll.isScrollEnabled = next == 0
    if next != 0 {
      publishingOffset = true
      homeDrive?.driveScroll.setContentOffset(.zero, animated: false)
      publishingOffset = false
    }
  }

  private func applyCartBadge(_ count: Int) {
    guard let items = tabController.tabBar.items, items.count > 2 else { return }
    items[2].badgeValue = count > 0 ? "\(min(count, 99))" : nil
  }

  func tabBarController(
    _ tabBarController: UITabBarController,
    shouldSelect viewController: UIViewController
  ) -> Bool {
    let index = tabBarController.viewControllers?.firstIndex(of: viewController) ?? 0
    channel?.invokeMethod("onTabSelected", arguments: index)
    return true
  }

  private func flutterAssetTabImage(_ asset: String) -> UIImage? {
    let key = FlutterDartProject.lookupKey(forAsset: asset)
    let path = (Bundle.main.bundlePath as NSString).appendingPathComponent(key)
    guard let source = UIImage(contentsOfFile: path) else { return nil }
    let side: CGFloat = 24
    let format = UIGraphicsImageRendererFormat.default()
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(
      size: CGSize(width: side, height: side),
      format: format
    )
    let drawn = renderer.image { _ in
      source.draw(in: CGRect(origin: .zero, size: CGSize(width: side, height: side)))
    }
    return drawn.withRenderingMode(.alwaysTemplate)
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
