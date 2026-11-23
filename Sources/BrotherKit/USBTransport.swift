import Foundation
import IOKit
import IOUSBHost

/// USB tiskárna nalezená v IORegistry (rozhraní třídy 7 = Printer).
public struct USBPrinterDevice: Identifiable, Hashable, Sendable {
    public let id: UInt64
    public let name: String
    public let vendorID: Int
    public let productID: Int
    public let serial: String?
    public let locationID: Int?

    public var isBrother: Bool { vendorID == 0x04F9 }

    public init(id: UInt64, name: String, vendorID: Int, productID: Int, serial: String?, locationID: Int?) {
        self.id = id; self.name = name; self.vendorID = vendorID; self.productID = productID
        self.serial = serial; self.locationID = locationID
    }
}

private enum IOReturnCode {
    static let exclusiveAccess = Int(Int32(bitPattern: 0xE000_02C5))
    static let timeout = Int(Int32(bitPattern: 0xE000_02D6))
    static let aborted = Int(Int32(bitPattern: 0xE000_02EB))
    static let usbTimeout = Int(Int32(bitPattern: 0xE000_4051))
    static let notResponding = Int(Int32(bitPattern: 0xE000_02ED))
}

/// Komunikace přes USB Printer Class (bulk OUT + bulk IN) pomocí IOUSBHost.
/// Nepotřebuje žádný ovladač – stejně jako původní Brother průvodce posíláme PJL příkazy přímo.
public final class USBPrinterTransport: PrinterTransport, @unchecked Sendable {
    public let kind: TransportKind = .usb
    public let displayName: String
    public let remoteHost: String? = nil
    public let device: USBPrinterDevice

    private let iface: IOUSBHostInterface
    private let outPipe: IOUSBHostPipe
    private let inPipe: IOUSBHostPipe
    private var isClosed = false

    // MARK: Enumerace

    public static func enumerate(brotherOnly: Bool = false) -> [USBPrinterDevice] {
        let matching = IOUSBHostInterface.__createMatchingDictionary(
            withVendorID: nil,
            productID: nil, bcdDevice: nil, interfaceNumber: nil, configurationValue: nil,
            interfaceClass: NSNumber(value: 7), interfaceSubclass: NSNumber(value: 1),
            interfaceProtocol: nil, speed: nil, productIDArray: nil
        ).takeRetainedValue()

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [USBPrinterDevice] = []
        var seen = Set<UInt64>()
        while true {
            let service = IOIteratorNext(iterator)
            if service == 0 { break }
            defer { IOObjectRelease(service) }

            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)

            func prop(_ key: String) -> Any? {
                IORegistryEntrySearchCFProperty(
                    service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                    IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
                )
            }
            let vendor = (prop("idVendor") as? NSNumber)?.intValue ?? 0
            let product = (prop("idProduct") as? NSNumber)?.intValue ?? 0
            let name = (prop("kUSBProductString") as? String)
                ?? (prop("USB Product Name") as? String)
                ?? L("USB printer")
            let vendorName = (prop("kUSBVendorString") as? String) ?? (prop("USB Vendor Name") as? String)
            let serial = (prop("kUSBSerialNumberString") as? String) ?? (prop("USB Serial Number") as? String)
            let location = (prop("locationID") as? NSNumber)?.intValue

            // Jedno zařízení může mít více rozhraní třídy 7 – zobrazíme ho jen jednou.
            let key = UInt64(UInt32(truncatingIfNeeded: location ?? Int(entryID)))
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            var display = name
            if let vendorName, !name.lowercased().contains(vendorName.lowercased()) {
                display = "\(vendorName) \(name)"
            }
            result.append(USBPrinterDevice(id: entryID, name: display, vendorID: vendor,
                                           productID: product, serial: serial, locationID: location))
        }
        if brotherOnly { result = result.filter(\.isBrother) }
        return result.sorted { ($0.isBrother ? 0 : 1, $0.name) < ($1.isBrother ? 0 : 1, $1.name) }
    }

    // MARK: Otevření

    public init(device: USBPrinterDevice) throws {
        self.device = device
        self.displayName = device.name

        guard let matching = IORegistryEntryIDMatching(device.id) else { throw TransportError.notFound }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { throw TransportError.notFound }
        defer { IOObjectRelease(service) }

        let iface: IOUSBHostInterface
        do {
            iface = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
        } catch {
            let ns = error as NSError
            if ns.code == IOReturnCode.exclusiveAccess { throw TransportError.busy }
            throw TransportError.openFailed(ns.localizedDescription)
        }
        self.iface = iface

        // Najdeme bulk IN/OUT. Pokud aktuální alternate setting nemá IN (unidirectional),
        // zkusíme další nastavení (protokol 2 = bidirectional).
        var endpoints = USBPrinterTransport.bulkEndpoints(of: iface)
        if endpoints.inAddr == nil {
            for alt in 1...3 {
                if (try? iface.selectAlternateSetting(alt)) != nil {
                    endpoints = USBPrinterTransport.bulkEndpoints(of: iface)
                    if endpoints.inAddr != nil { break }
                }
            }
        }
        guard let outAddr = endpoints.outAddr else {
            iface.destroy()
            throw TransportError.openFailed(L("The interface has no output endpoint."))
        }
        guard let inAddr = endpoints.inAddr else {
            iface.destroy()
            throw TransportError.notBidirectional
        }
        do {
            outPipe = try iface.copyPipe(withAddress: Int(outAddr))
            inPipe = try iface.copyPipe(withAddress: Int(inAddr))
        } catch {
            iface.destroy()
            throw TransportError.openFailed((error as NSError).localizedDescription)
        }
    }

    deinit { close() }

    private static func bulkEndpoints(of iface: IOUSBHostInterface) -> (inAddr: UInt8?, outAddr: UInt8?) {
        let config = iface.configurationDescriptor
        let ifDesc = iface.interfaceDescriptor
        var inAddr: UInt8?
        var outAddr: UInt8?
        var current: UnsafePointer<IOUSBDescriptorHeader>? = nil
        while let ep = IOUSBGetNextEndpointDescriptor(config, ifDesc, current) {
            let address = ep.pointee.bEndpointAddress
            let type = ep.pointee.bmAttributes & 0x03
            if type == 2 { // bulk
                if address & 0x80 != 0 { inAddr = inAddr ?? address } else { outAddr = outAddr ?? address }
            }
            current = UnsafeRawPointer(ep).assumingMemoryBound(to: IOUSBDescriptorHeader.self)
        }
        return (inAddr, outAddr)
    }

    /// Popis rozhraní pro diagnostiku.
    public var interfaceSummary: String {
        let d = iface.interfaceDescriptor.pointee
        let eps = USBPrinterTransport.bulkEndpoints(of: iface)
        return "if=\(d.bInterfaceNumber) alt=\(d.bAlternateSetting) class=\(d.bInterfaceClass)/\(d.bInterfaceSubClass)/\(d.bInterfaceProtocol) in=\(eps.inAddr.map { String(format: "0x%02X", $0) } ?? "-") out=\(eps.outAddr.map { String(format: "0x%02X", $0) } ?? "-")"
    }

    // MARK: IEEE 1284 Device ID

    /// Řetězec typu `MFG:Brother;CMD:PJL,...;MDL:HL-L2340D series;CLS:PRINTER;`
    public func ieee1284DeviceID() -> String? {
        let ifNum = UInt16(iface.interfaceDescriptor.pointee.bInterfaceNumber)
        let alt = UInt16(iface.interfaceDescriptor.pointee.bAlternateSetting)
        let request = IOUSBDeviceRequest(bmRequestType: 0xA1, bRequest: 0, wValue: 0,
                                         wIndex: (ifNum << 8) | alt, wLength: 1023)
        guard let data = NSMutableData(length: 1023) else { return nil }
        var transferred = 0
        do {
            try iface.__send(request, data: data, bytesTransferred: &transferred, completionTimeout: 2)
        } catch { return nil }
        guard transferred > 2 else { return nil }
        let bytes = data.bytes.assumingMemoryBound(to: UInt8.self)
        let declared = Int(bytes[0]) << 8 | Int(bytes[1])
        let length = min(max(declared, 2), transferred)
        let payload = Data(bytes: bytes + 2, count: length - 2)
        return String(decoding: payload, as: UTF8.self)
    }

    // MARK: I/O

    public func write(_ data: Data) throws {
        guard !isClosed else { throw TransportError.closed }
        let chunkSize = 16 * 1024
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = NSMutableData(data: data.subdata(in: offset..<end))
            var sent = 0
            do {
                try outPipe.__sendIORequest(with: chunk, bytesTransferred: &sent, completionTimeout: 300)
            } catch {
                throw TransportError.io((error as NSError).localizedDescription)
            }
            offset += max(sent, end - offset)
        }
    }

    public func read(maxLength: Int, timeout: TimeInterval) throws -> Data {
        guard !isClosed else { throw TransportError.closed }
        // Velikost čtení zarovnaná na násobek max. velikosti paketu (512 B pro High-Speed).
        let length = max(512, (maxLength / 512) * 512)
        guard let buffer = NSMutableData(length: length) else { return Data() }
        var received = 0
        do {
            try inPipe.__sendIORequest(with: buffer, bytesTransferred: &received, completionTimeout: max(0.05, timeout))
        } catch {
            let code = (error as NSError).code
            if ProcessInfo.processInfo.environment["PB_DEBUG"] != nil {
                FileHandle.standardError.write("[usb read] code=0x\(String(UInt32(bitPattern: Int32(truncatingIfNeeded: code)), radix: 16)) received=\(received) \((error as NSError).localizedDescription)\n".data(using: .utf8)!)
            }
            if received > 0 { return Data(bytes: buffer.bytes, count: received) }
            if [IOReturnCode.timeout, IOReturnCode.usbTimeout, IOReturnCode.aborted].contains(code) {
                return Data()
            }
            // Zaseknutý endpoint – zkusíme ho uvolnit a hlásíme prázdné čtení.
            if (try? inPipe.clearStall()) != nil { return Data() }
            throw TransportError.io((error as NSError).localizedDescription)
        }
        return Data(bytes: buffer.bytes, count: received)
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        iface.destroy()
    }
}
