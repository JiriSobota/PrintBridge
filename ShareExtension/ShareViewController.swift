import Cocoa
import UniformTypeIdentifiers

/// Share › PrintBridge extension: collects the shared files and hands them to the main app for printing.
@objc(ShareViewController)
final class ShareViewController: NSViewController {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        let label = NSTextField(labelWithString: "PrintBridge…")
        label.frame = NSRect(x: 20, y: 30, width: 280, height: 20)
        view.addSubview(label)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        collect { urls in
            DispatchQueue.main.async { self.finish(with: urls) }
        }
    }

    private func collect(_ done: @escaping ([URL]) -> Void) {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers {
            group.enter()
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { lock.lock(); urls.append(url); lock.unlock() }
                    group.leave()
                }
            } else if let type = [UTType.pdf, .image, .plainText, .rtf].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
                provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { tmp, _ in
                    // The temporary file disappears after this callback – copy it where the main app can read it.
                    if let tmp {
                        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PrintBridgeShare", isDirectory: true)
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        let dest = dir.appendingPathComponent(UUID().uuidString + "-" + tmp.lastPathComponent)
                        if (try? FileManager.default.copyItem(at: tmp, to: dest)) != nil {
                            lock.lock(); urls.append(dest); lock.unlock()
                        }
                    }
                    group.leave()
                }
            } else {
                group.leave()
            }
        }
        group.notify(queue: .global()) { done(urls) }
    }

    private func finish(with urls: [URL]) {
        var components = URLComponents()
        components.scheme = "printbridge"
        components.host = "print"
        components.queryItems = urls.map { URLQueryItem(name: "file", value: $0.path) }
        if !urls.isEmpty, let url = components.url {
            NSWorkspace.shared.open(url)
        }
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}
