import SwiftUI
import BrotherKit

struct ConnectView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Page {
            PageHeader(title: L("Connection"), subtitle: L("Choose a printer connected via USB or on your local network."), symbol: "cable.connector")

            if case .failed(let message) = model.connection {
                Banner(style: .error, title: L("Could not connect"), message: message)
            }

            Card("USB", symbol: "cable.connector.horizontal",
                 trailing: AnyView(Button { model.refreshUSB() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help(L("Refresh")))) {
                if model.usbDevices.isEmpty {
                    EmptyHint(symbol: "cable.connector.slash",
                              text: L("No USB printer. Connect your printer with a cable and turn it on – the list refreshes automatically."))
                } else {
                    VStack(spacing: 8) {
                        ForEach(model.usbDevices) { device in
                            DeviceRow(symbol: "printer.fill", title: device.name,
                                      subtitle: subtitle(for: device), highlight: device.isBrother) {
                                Task { await model.connect(usb: device) }
                            }
                        }
                    }
                }
                Text(L("Over USB you can set up Wi‑Fi even when the printer is not on any network – just like Brother’s original wizard."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Card(L("On the network"), symbol: "network") {
                if model.networkPrinters.isEmpty {
                    EmptyHint(symbol: "wifi.exclamationmark",
                              text: L("No printer found on the network yet (Bonjour, port 9100)."))
                } else {
                    VStack(spacing: 8) {
                        ForEach(model.networkPrinters) { printer in
                            DeviceRow(symbol: "wifi", title: printer.name, subtitle: L("Bonjour · RAW port"),
                                      highlight: printer.name.localizedCaseInsensitiveContains("brother")) {
                                Task { await model.connect(network: printer) }
                            }
                        }
                    }
                }
                Divider()
                HStack {
                    TextField(L("Printer IP address, e.g. 192.168.1.50"), text: $model.manualHost)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await model.connectManual() } }
                    Button(L("Connect")) { Task { await model.connectManual() } }
                        .disabled(model.manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Banner(style: .info, title: "Tip",
                   message: L("While macOS is printing, the USB interface is busy. Wait for printing to finish or pause the print queue."))
        }
    }

    func subtitle(for device: USBPrinterDevice) -> String {
        var parts = [String(format: "VID %04X · PID %04X", device.vendorID, device.productID)]
        if let serial = device.serial, !serial.isEmpty { parts.append("S/N \(serial)") }
        return parts.joined(separator: " · ")
    }
}

struct EmptyHint: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }
}

struct DeviceRow: View {
    @Environment(AppModel.self) private var model
    let symbol: String
    let title: String
    let subtitle: String
    let highlight: Bool
    let action: () -> Void
    @LocalState private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(highlight ? Color.white : Color.secondary)
                .frame(width: 34, height: 34)
                .background(highlight ? AnyShapeStyle(LinearGradient(colors: [.brandA, .brandB], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(Color.secondary.opacity(0.15)),
                            in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if case .connecting(let name) = model.connection, name == title {
                ProgressView().controlSize(.small)
            } else {
                Button(L("Connect"), action: action).buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(10)
        .background(hover ? Color.secondary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .onHover { hover = $0 }
    }
}
