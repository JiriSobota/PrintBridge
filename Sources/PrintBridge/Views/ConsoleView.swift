import SwiftUI
import BrotherKit

struct ConsoleView: View {
    @Environment(AppModel.self) private var model
    @LocalState private var input = "@PJL INFO STATUS"

    let presets: [(String, String)] = [
        (L("Identification"), "@PJL INFO ID"),
        (L("Status"), "@PJL INFO STATUS"),
        (L("Page counter"), "@PJL INFO PAGECOUNT"),
        (L("Configuration"), "@PJL INFO CONFIG"),
        (L("Variables"), "@PJL INFO VARIABLES"),
        (L("Firmware (Brother)"), "@PJL INFO BRFIRMWARE"),
        (L("Wi‑Fi scan result"), "@PJL INFO AVAILABLEWLAN"),
        (L("Wi‑Fi setup status"), "@PJL DEFAULT OBJBRNET=\"458867\"\n@PJL INQUIRE OBJBRNET"),
        (L("WLAN error code"), "@PJL DEFAULT OBJBRNET=\"459619\"\n@PJL INQUIRE OBJBRNET"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                PageHeader(title: L("Console"), subtitle: L("Talk to the printer directly in PJL – for diagnostics."), symbol: "terminal")
                Menu(L("Presets")) {
                    ForEach(presets, id: \.1) { preset in
                        Button(preset.0) { input = preset.1 }
                    }
                }
                .fixedSize()
                Button { model.exportLog() } label: { Label(L("Save log"), systemImage: "square.and.arrow.down") }
                Button { model.log.removeAll() } label: { Label(L("Clear"), systemImage: "trash") }
            }
            .padding([.horizontal, .top], 24)
            .padding(.bottom, 12)

            LogList(entries: model.log)
                .background(.background.secondary)

            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $input)
                    .font(.body.monospaced())
                    .frame(height: 64)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                HStack {
                    Text(L("One command per line. The job is wrapped in ESC%-12345X automatically. Use commands that change settings with care."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Send")) { Task { await model.sendRaw(input) } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!model.connection.isConnected || model.activity != nil)
                }
            }
            .padding(16)
        }
    }
}

struct LogList: View {
    let entries: [LogEntry]
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(entries) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Text(Self.formatter.string(from: entry.date))
                                .foregroundStyle(.tertiary)
                            Image(systemName: symbol(entry.direction))
                                .foregroundStyle(color(entry.direction))
                                .frame(width: 14)
                            Text(entry.text)
                                .foregroundStyle(entry.direction == .error ? .red : .primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .id(entry.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: entries.count) {
                if let last = entries.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    func symbol(_ d: LogEntry.Direction) -> String {
        switch d {
        case .outbound: return "arrow.up.right"
        case .inbound: return "arrow.down.left"
        case .info: return "circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    func color(_ d: LogEntry.Direction) -> Color {
        switch d {
        case .outbound: return .blue
        case .inbound: return .green
        case .info: return .secondary
        case .error: return .red
        }
    }
}
