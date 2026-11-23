import SwiftUI
import BrotherKit

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.section) {
                Section {
                    ForEach(AppSection.allCases) { section in
                        Label(section.title, systemImage: section.symbol).tag(section)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    ConnectionFooter()
                    HStack {
                        SettingsLink {
                            Label(L("Settings"), systemImage: "gearshape")
                        }
                        .buttonStyle(.borderless)
                        .font(.callout)
                        Spacer()
                        Text(L10n.languages.first { $0.code == L10n.current }?.name ?? "")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 4)
                }
                .padding(12)
            }
        } detail: {
            ZStack(alignment: .bottom) {
                Group {
                    switch model.section {
                    case .connect: ConnectView()
                    case .overview: OverviewView()
                    case .print: PrintView()
                    case .wifi: WiFiView()
                    case .firmware: FirmwareView()
                    case .console: ConsoleView()
                    case .tips: TipsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if let activity = model.activity {
                    ActivityToast(text: activity)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.3), value: model.activity)
        }
        .onAppear {
            // Soubory předané při spuštění (Otevřít v, Služby) – přepni rovnou na Tisk.
            if !model.printItems.isEmpty { model.section = .print }
        }
        .tint(.brandA)
        .id(model.languageRevision)
    }
}

struct ActivityToast: View {
    @Environment(AppModel.self) private var model
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.callout.weight(.medium))
            Button(L("Cancel")) { model.cancelActivity() }
                .buttonStyle(.borderless)
                .font(.callout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}

struct ConnectionFooter: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if model.connection.isConnected {
                Button { model.disconnect() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(L("Disconnect"))
            }
        }
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    var icon: String {
        switch model.connection {
        case .connected(_, let kind, _): return kind == .usb ? "cable.connector" : "wifi"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle"
        case .disconnected: return "powerplug"
        }
    }

    var color: Color {
        switch model.connection {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .disconnected: return .secondary
        }
    }

    var title: String {
        switch model.connection {
        case .connected(let name, _, _): return name
        case .connecting(let name): return L("Connecting… %@", name)
        case .failed: return L("Connection failed")
        case .disconnected: return L("Not connected")
        }
    }

    var subtitle: String {
        switch model.connection {
        case .connected(_, let kind, let host): return host.map { "\(L(kind.rawValue)) · \($0)" } ?? L(kind.rawValue)
        case .connecting: return L("Waiting for the printer")
        case .failed(let message): return message
        case .disconnected: return L("Choose a printer")
        }
    }
}
