import AppKit
import BrotherKit
import PDFKit
import QuickLookThumbnailing
import ServiceManagement

/// Soubor připravený k tisku.
struct PrintItem: Identifiable, Hashable {
    enum Kind: Hashable { case direct, convert, unsupported }

    let id = UUID()
    let url: URL
    let kind: Kind
    var pages: Int?
    var thumbnail: NSImage?

    var name: String { url.lastPathComponent }

    var kindTitle: String {
        switch kind {
        case .direct: return pages.map { L("Pages: %d", $0) } ?? url.pathExtension.uppercased()
        case .convert: return L("will be converted to PDF")
        case .unsupported: return L("opens in its own app")
        }
    }

    init(url: URL) {
        self.url = url
        let ext = url.pathExtension.lowercased()
        if PrintSystem.directTypes.contains(ext) {
            kind = .direct
        } else if DocumentConverter.convertibleTypes.contains(ext) {
            kind = .convert
        } else {
            kind = .unsupported
        }
        if ext == "pdf" { pages = PDFDocument(url: url)?.pageCount }
    }
}

/// Převod textových dokumentů (Word, RTF, ODT, HTML…) do PDF přes vestavěný AppKit.
@MainActor
enum DocumentConverter {
    nonisolated static let convertibleTypes: Set<String> = ["rtf", "rtfd", "doc", "docx", "odt", "html", "htm", "webarchive", "md", "csv", "xml", "json", "swift", "log"]

    static func pdf(for item: PrintItem) throws -> URL {
        switch item.kind {
        case .direct:
            return item.url
        case .convert:
            return try convertToPDF(item.url)
        case .unsupported:
            throw PrintSystemError.command(L("Cannot convert %@.", item.name))
        }
    }

    static func convertToPDF(_ url: URL) throws -> URL {
        let ext = url.pathExtension.lowercased()
        let text: NSAttributedString
        if ["md", "csv", "xml", "json", "swift", "log"].contains(ext) {
            let raw = try String(contentsOf: url, encoding: .utf8)
            text = NSAttributedString(string: raw, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)])
        } else {
            text = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        }

        let paper = NSSize(width: 595, height: 842) // A4 v bodech
        let margin: CGFloat = 56
        let info = NSPrintInfo()
        info.paperSize = paper
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.isHorizontallyCentered = false

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PrintBridge", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent).appendingPathExtension("pdf")
        try? FileManager.default.removeItem(at: out)
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out

        let width = paper.width - 2 * margin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: paper.height - 2 * margin))
        view.isVerticallyResizable = true
        view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(text)
        view.sizeToFit()

        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run(), FileManager.default.fileExists(atPath: out.path) else {
            throw PrintSystemError.command(L("Converting %@ to PDF failed.", url.lastPathComponent))
        }
        return out
    }

    static func thumbnail(for url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 128),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// Příjem souborů z Finderu (Služby, Otevřít v, přetažení na Dock) a z rozšíření Sdílet.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        if DemoMode.isEnabled, let dir = DemoMode.snapshotDirectory {
            Task { @MainActor in await DemoMode.takeSnapshots(model: AppModel.shared, into: dir) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        var files: [URL] = []
        for url in urls {
            if url.isFileURL {
                files.append(url)
            } else if url.scheme == "printbridge",
                      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
                files += items.filter { $0.name == "file" }.compactMap { $0.value }.map { URL(fileURLWithPath: $0) }
            }
        }
        guard !files.isEmpty else { return }
        Task { @MainActor in AppModel.shared.receivePrintFiles(files) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Služba „Vytisknout přes PrintBridge“ (NSServices v Info.plist).
    @objc func printFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else {
            error.pointee = L("No files were selected.") as NSString
            return
        }
        Task { @MainActor in
            AppModel.shared.receivePrintFiles(urls)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
