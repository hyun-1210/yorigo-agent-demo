//
//  ShareViewController.swift
//  ShareExtension
//
//  Created by Joonseok Kang on 11/21/25.
//

import UIKit
import MobileCoreServices

class ShareViewController: UIViewController {
    
    // MUST match Runner.entitlements + ShareExtension.entitlements (application-groups).
    private let appGroupId = "group.com.yorigo.kr.shared"
    private let urlSchemeHost = "share"
    private let urlSchemeName = "yorigo"
    private let shareTypePriority = [
        kUTTypeURL as String,
        kUTTypeFileURL as String,
        kUTTypeText as String,
        "public.plain-text",
        kUTTypeHTML as String,
        "public.html",
    ]

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        print("[ShareExtension] viewDidAppear - starting")
        
        // Show a loading indicator
        let activityIndicator = UIActivityIndicatorView(style: .medium)
        activityIndicator.center = view.center
        activityIndicator.startAnimating()
        view.addSubview(activityIndicator)
        view.backgroundColor = UIColor(white: 0, alpha: 0.3)
        
        // Process the shared content
        handleSharedContent()
    }

    private func handleSharedContent() {
        print("[ShareExtension] handleSharedContent called")
        
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem else {
            print("[ShareExtension] ERROR: No extension items found")
            self.closeExtension()
            return
        }
        
        print("[ShareExtension] Found extension item")
        
        let attachments = extensionItem.attachments ?? []
        print("[ShareExtension] Found \(attachments.count) attachments")
        tryLoad(from: attachments, attachmentIndex: 0, typeIndex: 0, extensionItem: extensionItem)
    }

    private func tryLoad(
        from attachments: [NSItemProvider],
        attachmentIndex: Int,
        typeIndex: Int,
        extensionItem: NSExtensionItem
    ) {
        if attachmentIndex >= attachments.count {
            if let textContent = extensionItem.attributedContentText?.string, !textContent.isEmpty {
                print("[ShareExtension] Found text in attributedContentText: \(textContent)")
                saveAndOpen(text: textContent)
                return
            }
            if let title = extensionItem.attributedTitle?.string, !title.isEmpty {
                print("[ShareExtension] Found text in attributedTitle: \(title)")
                saveAndOpen(text: title)
                return
            }
            print("[ShareExtension] ERROR: No content found to share")
            closeExtension()
            return
        }
        if typeIndex >= shareTypePriority.count {
            tryLoad(
                from: attachments,
                attachmentIndex: attachmentIndex + 1,
                typeIndex: 0,
                extensionItem: extensionItem
            )
            return
        }

        let provider = attachments[attachmentIndex]
        let typeId = shareTypePriority[typeIndex]
        guard provider.hasItemConformingToTypeIdentifier(typeId) else {
            tryLoad(
                from: attachments,
                attachmentIndex: attachmentIndex,
                typeIndex: typeIndex + 1,
                extensionItem: extensionItem
            )
            return
        }

        print("[ShareExtension] Loading attachment \(attachmentIndex) type=\(typeId)")
        provider.loadItem(forTypeIdentifier: typeId, options: nil) { [weak self] item, error in
            if let error = error {
                print("[ShareExtension] Error loading \(typeId): \(error)")
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if let str = self.normalizedShareString(from: item), !str.isEmpty {
                    let extracted = self.extractUrl(from: str)
                    if extracted.lowercased().hasPrefix("file://") {
                        print("[ShareExtension] Skipping local file URL: \(extracted)")
                    } else {
                        print("[ShareExtension] Got payload: \(str)")
                        self.saveAndOpen(text: str)
                        return
                    }
                } else {
                    print("[ShareExtension] Unexpected payload type: \(type(of: item))")
                }
                self.tryLoad(
                    from: attachments,
                    attachmentIndex: attachmentIndex,
                    typeIndex: typeIndex + 1,
                    extensionItem: extensionItem
                )
            }
        }
    }

    private func saveAndOpen(text: String) {
        print("[ShareExtension] saveAndOpen called with text: \(text)")
        
        let url = extractUrl(from: text)
        print("[ShareExtension] Extracted URL: \(url)")
        
        if let sharedDefaults = UserDefaults(suiteName: appGroupId) {
            print("[ShareExtension] ✅ Successfully accessed App Group UserDefaults")
            sharedDefaults.set(url, forKey: "sharedUrl")
            let success = sharedDefaults.synchronize()
            print("[ShareExtension] Synchronize result: \(success)")
            
            if let savedUrl = sharedDefaults.string(forKey: "sharedUrl") {
                print("[ShareExtension] ✅ Verified saved URL: \(savedUrl)")
            } else {
                print("[ShareExtension] ⚠️ WARNING: Could not verify saved URL")
            }
        } else {
            print("[ShareExtension] ❌ ERROR: Could not access App Group UserDefaults")
            print("[ShareExtension] App Group ID: \(appGroupId)")
            print("[ShareExtension] This means App Groups are not properly configured in Xcode")
        }
        
        openMainApp(sharedUrl: url)
    }
    
    /// YouTube/Instagram often vend `NSURL` or `NSString` from `loadItem`, not Swift `URL`/`String`.
    private func normalizedShareString(from item: Any?) -> String? {
        guard let item = item else { return nil }
        if let url = item as? URL {
            return url.absoluteString
        }
        if let nsUrl = item as? NSURL {
            return nsUrl.absoluteString
        }
        if let str = item as? String {
            return str
        }
        if let nsStr = item as? NSString {
            return nsStr as String
        }
        if let attributed = item as? NSAttributedString {
            return attributed.string
        }
        if let data = item as? Data, let str = String(data: data, encoding: .utf8) {
            return str
        }
        return nil
    }

    private func extractUrl(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return trimmed
        }
        
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        if let match = detector?.firstMatch(in: trimmed, options: [], range: range),
           let urlRange = Range(match.range, in: trimmed) {
            return String(trimmed[urlRange])
        }

        let hosts = [
            "youtube.com", "youtu.be", "instagram.com", "instagr.am",
            "tiktok.com", "naver.com", "naver.me",
        ]
        if hosts.contains(where: { lower.contains($0) }) {
            if trimmed.contains("://") {
                return trimmed
            }
            return "https://\(trimmed)"
        }
        
        return trimmed
    }
    
    private func openMainApp(sharedUrl: String) {
        var components = URLComponents()
        components.scheme = urlSchemeName
        components.host = urlSchemeHost
        components.queryItems = [URLQueryItem(name: "url", value: sharedUrl)]
        let url = components.url ?? URL(string: "\(urlSchemeName)://\(urlSchemeHost)")
        print("[ShareExtension] Opening main app with URL scheme: \(url?.absoluteString ?? "nil")")
        guard let url else {
            closeExtension()
            return
        }
        // `extensionContext.open` alone often leaves YouTube/Instagram in the foreground.
        // Opening via UIApplication from the responder chain reliably activates the host app.
        if openHostApplication(url: url) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            }
            return
        }
        extensionContext?.open(url, completionHandler: { [weak self] success in
            print("[ShareExtension] extensionContext.open result: \(success)")
            self?.closeExtension()
        })
    }

    /// 호스트 앱으로 커스텀 스킴을 연다. Share Extension에서는 `UIApplication.shared`를 쓸 수 없어
    /// responder chain에서 `UIApplication`을 찾는 방식이 일반적이다.
    @discardableResult
    private func openHostApplication(url: URL) -> Bool {
        var responder: UIResponder? = self
        while let r = responder {
            if let application = r as? UIApplication {
                application.open(url, options: [:], completionHandler: { success in
                    print("[ShareExtension] UIApplication.open (responder chain): \(success)")
                })
                return true
            }
            responder = r.next
        }
        return false
    }
    
    private func closeExtension() {
        print("[ShareExtension] Closing extension")
        self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
