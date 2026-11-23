import AppKit
import BrotherKit
import Network

/// Demo mode for screenshots and UI testing – no printer needed and no real data shown.
///
///     PB_DEMO=1 PB_LANG=en open build/PrintBridge.app
///     PB_DEMO=1 PB_LANG=en PB_SNAPSHOT=/tmp/shots build/PrintBridge.app/Contents/MacOS/PrintBridge
///
/// `PB_SNAPSHOT` renders every section to `<dir>/<section>.png` and quits.
enum DemoMode {
    static var isEnabled: Bool { ProcessInfo.processInfo.environment["PB_DEMO"] != nil }
    static var snapshotDirectory: URL? {
        ProcessInfo.processInfo.environment["PB_SNAPSHOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    @MainActor
    static func populate(_ model: AppModel) {
        let usb = USBPrinterDevice(id: 1, name: "Brother HL-L2340D series", vendorID: 0x04F9, productID: 0x0063,
                                   serial: "E00000A0N000000", locationID: nil)
        model.usbDevices = [usb]
        model.networkPrinters = [
            NetworkPrinter(id: "demo", name: "Brother HL-L2340D series",
                           endpoint: .service(name: "Brother HL-L2340D series", type: "_pdl-datastream._tcp", domain: "local.", interface: nil)),
        ]
        model.connection = .connected(name: "Brother HL-L2340D series", kind: .network, host: "192.168.1.50")
        model.status = PrinterStatus(model: "Brother HL-L2340D series", statusCode: 10001, display: "Ready",
                                     online: true, pageCount: 1284, firmwareVersion: "1.30")
        model.tonerPercent = 72
        model.currentNetwork = CurrentNetwork(ssid: "Home WiFi", ipAddress: "192.168.1.50", subnetMask: "255.255.255.0",
                                              gateway: "192.168.1.1", macAddress: "00:80:77:12:34:56",
                                              bootMethod: L("Automatic (DHCP)"), wirelessEnabled: true)
        model.scanResult = WiFiScanResult(networks: [
            WiFiNetwork(index: 0, ssid: "Home WiFi", channel: 6, signal: 3, security: 3, encryption: 4, wlanMode: 5, commMode: 1),
            WiFiNetwork(index: 1, ssid: "Office 2.4G", channel: 11, signal: 2, security: 3, encryption: 4, wlanMode: 5, commMode: 1),
            WiFiNetwork(index: 2, ssid: "Guest", channel: 1, signal: 1, security: 1, encryption: 1, wlanMode: 5, commMode: 1),
            WiFiNetwork(index: 3, ssid: "Neighbour", channel: 6, signal: 0, security: 3, encryption: 4, wlanMode: 5, commMode: 1),
        ])
        model.firmware = FirmwareInfo(model: "HL-L2340D series", spec: "0004", parts: [FirmwarePart(id: "MAIN", version: "1.15")])
        model.firmwareChecks = ["MAIN": .update(version: "1.30", url: URL(string: "https://update-akamai.brother.co.jp/CS/LZ5185_Z.djf")!)]
        model.queues = [
            PrintQueue(name: PrintSystem.queueName, uri: "ipp://BRW008077123456.local:631/ipp/print", isDefault: true, state: L("Ready")),
        ]
        model.selectedQueue = PrintSystem.queueName
        model.jobs = [PrintJob(id: "\(PrintSystem.queueName)-42", user: "you", size: "2048", date: "", status: "Printing page 1 of 3")]
        model.printItems = demoFiles().map(PrintItem.init(url:))
        for (i, item) in model.printItems.enumerated() {
            Task {
                let image = await DocumentConverter.thumbnail(for: item.url)
                if i < model.printItems.count { model.printItems[i].thumbnail = image }
            }
        }
        model.log = [
            LogEntry(.info, "Connected (Network)."),
            LogEntry(.outbound, "@PJL INFO ID\n@PJL INFO STATUS"),
            LogEntry(.inbound, "@PJL INFO ID\n\"Brother HL-L2340D series:84U-F56:Ver.1.30\"⏎@PJL INFO STATUS\nCODE=10001\nDISPLAY=\"Ready\"\nONLINE=TRUE⏎"),
            LogEntry(.outbound, "@PJL RDYMSG DISPLAY = \"HELLO WORLD\""),
        ]
    }

    /// Sample files rendered into a temporary folder (a PDF and a text document).
    private static func demoFiles() -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PrintBridgeDemo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pdf = dir.appendingPathComponent("Quarterly report.pdf")
        if !FileManager.default.fileExists(atPath: pdf.path) {
            var box = CGRect(x: 0, y: 0, width: 595, height: 842)
            if let ctx = CGContext(pdf as CFURL, mediaBox: &box, nil) {
                for page in 1...3 {
                    ctx.beginPDFPage(nil)
                    ctx.setFillColor(NSColor(calibratedRed: 0.23, green: 0.45, blue: 0.98, alpha: 1).cgColor)
                    ctx.fill(CGRect(x: 56, y: 740, width: 483, height: 48))
                    ctx.setFillColor(NSColor(white: 0.85, alpha: 1).cgColor)
                    for line in 0..<18 { ctx.fill(CGRect(x: 56, y: 680 - line * 30, width: line % 4 == 3 ? 300 : 483, height: 10)) }
                    ctx.setFillColor(NSColor(calibratedRed: 0.36, green: 0.8, blue: 0.86, alpha: 1).cgColor)
                    ctx.fill(CGRect(x: 56, y: 80, width: CGFloat(120 * page), height: 60))
                    ctx.endPDFPage()
                }
                ctx.closePDF()
            }
        }
        let rtf = dir.appendingPathComponent("Letter.rtf")
        if !FileManager.default.fileExists(atPath: rtf.path) {
            let text = NSAttributedString(string: "Dear customer,\n\nthank you for your order.\n",
                                          attributes: [.font: NSFont.systemFont(ofSize: 14)])
            if let data = try? text.data(from: NSRange(location: 0, length: text.length),
                                         documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                try? data.write(to: rtf)
            }
        }
        return [pdf, rtf]
    }

    /// Renders each section of the main window into PNG files, then quits.
    @MainActor
    static func takeSnapshots(model: AppModel, into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }) else { NSApp.terminate(nil); return }
        window.setContentSize(NSSize(width: 1120, height: 760))
        window.center()
        for section in [AppSection.overview, .wifi, .print, .firmware, .connect, .console, .tips] {
            model.section = section
            try? await Task.sleep(for: .seconds(1.5))
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent("\(section.rawValue).png"))
            }
        }
        NSApp.terminate(nil)
    }
}
