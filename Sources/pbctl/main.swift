import Foundation
import BrotherKit

// Ladicí nástroj: pbctl list | pbctl pjl "<příkaz>"... | pbctl send <soubor>
let args = Array(CommandLine.arguments.dropFirst())
let log: LogSink = { entry in
    let mark: String
    switch entry.direction {
    case .outbound: mark = "→"
    case .inbound: mark = "←"
    case .info: mark = "•"
    case .error: mark = "!"
    }
    FileHandle.standardError.write("\(mark) \(entry.text)\n".data(using: .utf8)!)
}

func openUSB() throws -> USBPrinterTransport {
    guard let device = USBPrinterTransport.enumerate(brotherOnly: true).first else { throw TransportError.notFound }
    return try USBPrinterTransport(device: device)
}

do {
    switch args.first {
    case "list":
        for d in USBPrinterTransport.enumerate() {
            print("\(d.name)  VID \(String(format: "%04X", d.vendorID)) PID \(String(format: "%04X", d.productID))  S/N \(d.serial ?? "-")")
        }
    case "pjl":
        let t = try openUSB()
        defer { t.close() }
        print("DeviceID: \(t.ieee1284DeviceID() ?? "-")")
        print("Rozhraní: \(t.interfaceSummary)")
        let s = PJLSession(transport: t, log: log)
        print(try s.query(Array(args.dropFirst()), timeout: 30, idle: 4))
    case "queues":
        for q in PrintSystem.queues() {
            print("\(q.isDefault ? "*" : " ") \(q.name) [\(q.state)] \(q.connection) \(q.message ?? "")\(q.usesFragileDiscovery ? "  ⚠︎ Bonjour" : "")")
        }
        for j in PrintSystem.jobs(queue: nil) { print("  úloha \(j.id) \(j.size) \(j.status ?? "")") }
    case "discover":
        for u in PrintSystem.discoverPrinterURIs() { print(u) }
    case "probe":
        let t = try openUSB()
        defer { t.close() }
        let start = Date()
        func el() -> String { String(format: "%5.1fs", Date().timeIntervalSince(start)) }
        try t.write(PJL.job(["@PJL INFO STATUS"]))
        print("\(el()) odeslán dotaz")
        var step = 0
        while Date().timeIntervalSince(start) < 40 {
            let d = try t.read(maxLength: 16384, timeout: 1)
            if !d.isEmpty { print("\(el()) přijato \(d.count) B: \(String(decoding: d, as: UTF8.self).replacingOccurrences(of: "\r\n", with: " | "))") }
            let e = Date().timeIntervalSince(start)
            if step == 0 && e > 8 { step = 1; try t.write(Data(PJL.uel.utf8)); print("\(el()) poslán samotný UEL") }
            if step == 1 && e > 16 { step = 2; try t.write(PJL.job(["@PJL ECHO PB"])); print("\(el()) poslán ECHO") }
            if step == 2 && e > 24 { step = 3; try t.write(PJL.job(["@PJL INFO ID"])); print("\(el()) poslán INFO ID") }
        }
    case "send":
        guard args.count == 2 else { throw TransportError.io("použití: pbctl send <soubor>") }
        let data = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        let t = try openUSB()
        defer { t.close() }
        let s = PJLSession(transport: t, log: log)
        var last = -1
        try s.sendRaw(data, progress: { p in
            let pct = Int(p * 100)
            if pct / 5 != last / 5 { last = pct; FileHandle.standardError.write("\rodesláno \(pct) %".data(using: .utf8)!) }
        }, isCancelled: { false })
        FileHandle.standardError.write("\nHotovo: odesláno \(data.count) B\n".data(using: .utf8)!)
    default:
        print("pbctl list | pjl \"@PJL INFO ID\" ... | send <soubor>")
    }
} catch {
    FileHandle.standardError.write("Chyba: \((error as? LocalizedError)?.errorDescription ?? "\(error)")\n".data(using: .utf8)!)
    exit(1)
}
