import Flutter
import UIKit

/// Official iPhone action sheet: `UIAlertController(preferredStyle: .actionSheet)`.
///
/// iOS 26 SDK applies Liquid Glass automatically. Do not restyle the
/// controller — that opts out of the system material (WWDC25).
final class IosActionSheetPlugin: NSObject {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "yorigo.app/ios_action_sheet",
      binaryMessenger: registrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard UIDevice.current.userInterfaceIdiom == .phone else {
        result(
          FlutterError(
            code: "unsupported",
            message: "Native dialogs are iPhone-only",
            details: nil
          )
        )
        return
      }
      guard let args = call.arguments as? [String: Any] else {
        result(FlutterError(code: "bad_args", message: nil, details: nil))
        return
      }
      switch call.method {
      case "show":
        present(args: args, style: .actionSheet, result: result)
      case "showConfirm":
        presentConfirm(args: args, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func presentConfirm(
    args: [String: Any],
    result: @escaping FlutterResult
  ) {
    guard let host = topViewController() else {
      result(FlutterError(code: "no_host", message: nil, details: nil))
      return
    }
    let title = (args["title"] as? String)?.nilIfEmpty
    let message = (args["message"] as? String)?.nilIfEmpty
    let cancel = (args["cancelLabel"] as? String)?.nilIfEmpty ?? "취소"
    let confirm = (args["confirmLabel"] as? String)?.nilIfEmpty ?? "확인"
    let destructive = args["destructive"] as? Bool ?? false

    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(
      UIAlertAction(title: cancel, style: .cancel) { _ in
        result(false)
      }
    )
    alert.addAction(
      UIAlertAction(
        title: confirm,
        style: destructive ? .destructive : .default
      ) { _ in
        result(true)
      }
    )
    host.present(alert, animated: true)
  }

  private static func present(
    args: [String: Any],
    style: UIAlertController.Style,
    result: @escaping FlutterResult
  ) {
    guard let host = topViewController() else {
      result(FlutterError(code: "no_host", message: nil, details: nil))
      return
    }
    let title = args["title"] as? String
    let message = args["message"] as? String
    let cancel = (args["cancelLabel"] as? String)?.nilIfEmpty ?? "취소"
    let rawActions = (args["actions"] as? [[String: Any]]) ?? []

    let sheet = UIAlertController(
      title: title?.nilIfEmpty,
      message: message?.nilIfEmpty,
      preferredStyle: style
    )
    for item in rawActions {
      let id = item["id"] as? String ?? ""
      let label = item["title"] as? String ?? id
      let destructive = item["destructive"] as? Bool ?? false
      guard !id.isEmpty, !label.isEmpty else { continue }
      sheet.addAction(
        UIAlertAction(
          title: label,
          style: destructive ? .destructive : .default
        ) { _ in
          result(id)
        }
      )
    }
    sheet.addAction(
      UIAlertAction(title: cancel, style: .cancel) { _ in
        result(nil)
      }
    )
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = host.view
      popover.sourceRect = CGRect(
        x: host.view.bounds.midX,
        y: host.view.bounds.maxY - 12,
        width: 1,
        height: 1
      )
    }
    host.present(sheet, animated: true)
  }

  private static func topViewController(
    from root: UIViewController? = keyRootViewController()
  ) -> UIViewController? {
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

  private static func keyRootViewController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
    let window = windows.first(where: \.isKeyWindow) ?? windows.first
    return window?.rootViewController
  }
}

private extension String {
  var nilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
