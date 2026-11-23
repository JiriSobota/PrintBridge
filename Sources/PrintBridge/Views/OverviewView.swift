import SwiftUI
import BrotherKit

struct OverviewView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.connection.isConnected {
            NotConnectedView()
        } else {
            Page {
                PageHeader(title: model.status?.model ?? L("Printer"), subtitle: subtitle, symbol: "printer.fill")

                if let error = model.lastError {
                    Banner(style: .error, title: L("Error"), message: error)
                }

                HStack(alignment: .top, spacing: 16) {
                    StatTile(title: L("Status"), value: model.status?.statusTitle ?? "—",
                             symbol: model.status?.isError == true ? "exclamationmark.triangle.fill" : "checkmark.seal.fill",
                             color: model.status?.isError == true ? .orange : .green)
                    StatTile(title: L("Pages printed"), value: model.status?.pageCount.map { $0.formatted(.number.locale(L10n.locale)) } ?? "—",
                             symbol: "doc.on.doc.fill", color: .brandA)
                    StatTile(title: "Toner", value: model.tonerPercent.map { "\($0) %" } ?? (model.isUSB ? L("via network") : "—"),
                             symbol: "drop.fill", color: .purple)
                }

                Card(L("Details"), symbol: "list.bullet.rectangle",
                     trailing: AnyView(Button(L("Refresh")) { Task { await model.refreshStatus() } }.controlSize(.small))) {
                    VStack(spacing: 8) {
                        InfoRow(label: "Model", value: model.status?.model)
                        InfoRow(label: "Firmware", value: model.status?.firmwareVersion, monospaced: true)
                        InfoRow(label: L("Printer display"), value: model.status?.display)
                        InfoRow(label: L("Status code"), value: model.status?.statusCode.map(String.init), monospaced: true)
                        InfoRow(label: "Online", value: model.status?.online.map { $0 ? L("Yes") : L("No") })
                        if let host = model.host { InfoRow(label: L("Address"), value: host, monospaced: true) }
                        if let id = model.status?.deviceID {
                            InfoRow(label: "IEEE 1284 ID", value: id, monospaced: true)
                        }
                    }
                }

                DisplayCard()

                Card(L("Quick actions"), symbol: "bolt.fill") {
                    HStack(spacing: 10) {
                        ActionButton(title: L("Set Up Wi‑Fi"), symbol: "wifi") { model.section = .wifi }
                        ActionButton(title: L("Check Firmware"), symbol: "arrow.down.circle") { model.section = .firmware }
                        if let host = model.host {
                            ActionButton(title: L("Web Interface"), symbol: "safari") {
                                if let url = URL(string: "http://\(host)") { NSWorkspace.shared.open(url) }
                            }
                        }
                        ActionButton(title: L("macOS Printers"), symbol: "gearshape") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
        }
    }

    var subtitle: String {
        switch model.connection {
        case .connected(_, let kind, let host):
            return L("Connected via %@", kind == .usb ? "USB" : L("network")) + (host.map { " · \($0)" } ?? "")
        default: return ""
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

struct ActionButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 18))
                Text(title).font(.caption.weight(.medium)).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
        }
        .buttonStyle(.bordered)
    }
}

struct DisplayCard: View {
    @Environment(AppModel.self) private var model
    @LocalState private var text = ""

    var body: some View {
        Card(L("Printer display"), symbol: "character.textbox") {
            HStack(spacing: 14) {
                Text(preview)
                    .font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(red: 0.1, green: 0.16, blue: 0.08))
                    .padding(.horizontal, 10)
                    .frame(width: 190, height: 34, alignment: .leading)
                    .background(Color(red: 0.66, green: 0.78, blue: 0.48), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.black.opacity(0.35), lineWidth: 2))
                TextField(L("Custom text (max. 16 characters)"), text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { send() }
                Button(L("Show")) { send() }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.isEmpty || model.activity != nil)
                Button(L("Default")) { Task { await model.setDisplay("") } }
                    .disabled(model.activity != nil)
            }
            Text(L("The text replaces “Ready” – it shows while the printer is awake (after a button press or a print). In sleep mode the display still shows “Sleep”. Accents are removed because the display can’t show them."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    var preview: String {
        let t = BrotherPrinter.displayText(text)
        return t.isEmpty ? "Ready" : t
    }

    func send() {
        guard !text.isEmpty else { return }
        Task { await model.setDisplay(text) }
    }
}
