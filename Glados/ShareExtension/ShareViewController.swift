import UIKit
import UniformTypeIdentifiers

class ShareViewController: UIViewController {

    private let appGroupID = "group.com.borr.scifm"
    private let urlDefaultsKey = "pendingArticleURL"

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        extractURL()
    }

    private func extractURL() {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = extensionItem.attachments
        else {
            finish()
            return
        }

        for provider in attachments {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] item, error in
                    if let url = item as? URL {
                        self?.handleURL(url)
                    } else if let str = item as? String, let url = URL(string: str) {
                        self?.handleURL(url)
                    } else {
                        self?.finish()
                    }
                }
                return
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { [weak self] item, error in
                    if let str = item as? String, let url = URL(string: str) {
                        self?.handleURL(url)
                    } else {
                        self?.finish()
                    }
                }
                return
            }
        }
        finish()
    }

    private func handleURL(_ url: URL) {
        // Write URL to the shared App Group — the main app picks it up on next foreground
        if let defaults = UserDefaults(suiteName: appGroupID) {
            defaults.set(url.absoluteString, forKey: urlDefaultsKey)
            defaults.synchronize()
        }
        finish()
    }

    private func finish() {
        DispatchQueue.main.async {
            self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
    }
}
