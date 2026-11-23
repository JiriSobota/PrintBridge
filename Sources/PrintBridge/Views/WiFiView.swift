import SwiftUI
import BrotherKit

struct WiFiView: View {
    @Environment(AppModel.self) private var model

    @LocalState private var ssid = ""
    @LocalState private var key = ""
    @LocalState private var showKey = false
    @LocalState private var security: WiFiSecurity = .automatic
    @LocalState private var useStaticIP = false
    @LocalState private var staticIP = StaticIPConfig()
    @LocalState private var selected: WiFiNetwork?
    @LocalState private var confirm = false

    var config: WiFiConfig {
        WiFiConfig(ssid: ssid, key: security.needsKey ? key : "", security: security,
                   wlanMode: selected?.wlanMode ?? 5, commMode: selected?.commMode ?? 1,
                   channel: selected?.channel ?? 0, staticIP: useStaticIP ? staticIP : nil)
    }

    var isRunning: Bool { if case .running = model.applyState { return true }; return false }

    var body: some View {
        if !model.connection.isConnected {
            NotConnectedView()
        } else {
            Page {
                PageHeader(title: "Wi‑Fi", subtitle: L("Connect the printer to your network – more reliably than the original wizard."), symbol: "wifi")

                switch model.applyState {
                case .running(let stage): ApplyProgressCard(stage: stage)
                case .done(let outcome): OutcomeCard(outcome: outcome)
                case .error(let message): Banner(style: .error, title: L("Could not send the settings"), message: message)
                case .idle: EmptyView()
                }

                networksCard
                settingsCard
                currentCard
            }
            .confirmationDialog(L("Connect the printer to “%@”?", ssid), isPresented: $confirm, titleVisibility: .visible) {
                Button(L("Send Settings")) { Task { await model.apply(config) } }
                Button(L("Cancel"), role: .cancel) {}
            } message: {
                Text(L("The printer leaves its current network and tries to join the new one. Verification takes up to 3 minutes – don’t turn it off meanwhile."))
            }
        }
    }

    // MARK: Dostupné sítě

    var networksCard: some View {
        Card(L("Available networks"), symbol: "antenna.radiowaves.left.and.right",
             trailing: AnyView(
                Button {
                    Task { await model.scan() }
                } label: {
                    Label(model.scanResult == nil ? L("Scan for Networks") : L("Scan Again"), systemImage: "magnifyingglass")
                }
                .controlSize(.small)
                .disabled(model.activity != nil)
             )) {
            if let progress = model.scanProgress {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(progress).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            } else if let result = model.scanResult {
                if result.networks.isEmpty {
                    EmptyHint(symbol: "wifi.slash", text: L("The printer found no networks. It only supports 2.4 GHz – check that your router broadcasts it."))
                    DisclosureGroup(L("Raw printer response")) {
                        Text(result.lines.joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    .font(.caption)
                } else {
                    VStack(spacing: 4) {
                        ForEach(result.networks) { network in
                            NetworkRow(network: network, isSelected: selected?.id == network.id)
                                .onTapGesture { pick(network) }
                        }
                    }
                }
            } else {
                EmptyHint(symbol: "wifi", text: L("Let the printer scan for nearby networks. You’ll see exactly what its antenna sees, including signal strength."))
            }
        }
    }

    func pick(_ network: WiFiNetwork) {
        selected = network
        ssid = network.ssid
        security = network.suggestedSecurity
        if network.security == 4 {
            model.lastError = L("“%@” uses WPA‑Enterprise, which this app cannot configure yet. Use the printer’s web interface.", network.ssid)
        }
    }

    // MARK: Nastavení

    var settingsCard: some View {
        Card(L("Connection settings"), symbol: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 14) {
                LabeledField(L("Network name (SSID)")) {
                    TextField(L("e.g. MyWiFi"), text: $ssid)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: ssid) { _, new in if new != selected?.ssid { selected = nil } }
                }

                LabeledField(L("Security")) {
                    Picker("", selection: $security) {
                        ForEach(WiFiSecurity.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 320, alignment: .leading)
                }

                if security.needsKey {
                    LabeledField(L("Password")) {
                        HStack {
                            Group {
                                if showKey { TextField(L("Wi‑Fi password"), text: $key) } else { SecureField(L("Wi‑Fi password"), text: $key) }
                            }
                            .textFieldStyle(.roundedBorder)
                            Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                                .buttonStyle(.borderless)
                                .help(showKey ? L("Hide password") : L("Show password"))
                        }
                    }
                }

                Toggle(L("Static IP address (instead of DHCP)"), isOn: $useStaticIP.animation())
                if useStaticIP {
                    HStack(spacing: 10) {
                        LabeledField(L("IP address")) { TextField("192.168.1.50", text: $staticIP.address).textFieldStyle(.roundedBorder) }
                        LabeledField(L("Subnet mask")) { TextField("255.255.255.0", text: $staticIP.mask).textFieldStyle(.roundedBorder) }
                        LabeledField(L("Gateway")) { TextField("192.168.1.1", text: $staticIP.gateway).textFieldStyle(.roundedBorder) }
                    }
                    Text(L("Tip: instead of a static IP, prefer a “DHCP reservation” for the printer’s MAC address on your router – it’s more reliable."))
                        .font(.caption).foregroundStyle(.secondary)
                }

                let problems = config.validate()
                if !problems.isEmpty && (!ssid.isEmpty || !key.isEmpty) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(problems, id: \.self) { Label($0, systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                    }
                    .font(.callout)
                }

                if security == .automatic {
                    Text(L("In “Automatic” mode the printer detects the router’s security type itself – just like Brother’s original wizard."))
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Button {
                        confirm = true
                    } label: {
                        Label(L("Connect Printer to Wi‑Fi"), systemImage: "paperplane.fill").padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!problems.isEmpty || isRunning || model.activity != nil)
                }
            }
        }
    }

    // MARK: Aktuální stav

    var currentCard: some View {
        Card(L("Current network settings"), symbol: "info.circle",
             trailing: AnyView(Button(L("Read")) { Task { await model.readCurrentNetwork() } }
                .controlSize(.small).disabled(model.activity != nil))) {
            if let net = model.currentNetwork {
                VStack(spacing: 8) {
                    InfoRow(label: L("Network (SSID)"), value: net.ssid)
                    InfoRow(label: L("IP address"), value: net.ipAddress, monospaced: true)
                    InfoRow(label: L("Subnet mask"), value: net.subnetMask, monospaced: true)
                    InfoRow(label: L("Gateway"), value: net.gateway, monospaced: true)
                    InfoRow(label: L("MAC address"), value: net.macAddress, monospaced: true)
                    InfoRow(label: L("IP assignment"), value: net.bootMethod)
                    InfoRow(label: L("Wi‑Fi enabled"), value: net.wirelessEnabled.map { $0 ? L("Yes") : L("No") })
                }
            } else {
                Text(L("Reads the stored values directly from the printer (OBJBRNET objects). Some firmware versions may not return all of them."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
    }
}

struct NetworkRow: View {
    let network: WiFiNetwork
    let isSelected: Bool
    @LocalState private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            SignalBars(bars: network.bars)
            VStack(alignment: .leading, spacing: 2) {
                Text(network.ssid.isEmpty ? L("‹hidden network›") : network.ssid).font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(network.securityTitle)
                    if let ch = network.channel { Text(L("· channel %d", ch)) }
                    if network.isAdHoc { Text(L("· ad‑hoc")) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: network.isSecured ? "lock.fill" : "lock.open").foregroundStyle(.secondary)
            if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isSelected ? Color.accentColor.opacity(0.12) : (hover ? Color.secondary.opacity(0.08) : .clear),
                    in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

struct ApplyProgressCard: View {
    @Environment(AppModel.self) private var model
    let stage: WiFiApplyStage

    var body: some View {
        Card(L("Connecting the printer…"), symbol: "wifi") {
            VStack(alignment: .leading, spacing: 10) {
                switch stage {
                case .sending:
                    Text(L("Sending settings to the printer…"))
                    ProgressView()
                case .retryingWithTKIP:
                    Text(L("AES failed, retrying with TKIP encryption…"))
                    ProgressView()
                case .readingResult:
                    Text(L("Asking the printer for the result…"))
                    ProgressView()
                case .waiting(let attempt, let total, let left):
                    Text(L("The printer is joining the router. Check %1$d of %2$d, next in %3$d s.", attempt, total, left))
                    ProgressView(value: Double(attempt - 1) + Double(15 - left) / 15, total: Double(total))
                }
                HStack {
                    Text(L("Don’t turn the printer off. Its display may show “Connecting WLAN”."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Stop Waiting")) { model.cancelActivity() }.controlSize(.small)
                }
            }
        }
    }
}

struct OutcomeCard: View {
    @Environment(AppModel.self) private var model
    let outcome: WiFiApplyOutcome

    var body: some View {
        switch outcome {
        case .connected(let ip):
            VStack(alignment: .leading, spacing: 10) {
                Banner(style: .success, title: L("The printer is connected to Wi‑Fi"),
                       message: ip.map { L("Printer IP address: %@. You can now unplug USB and add it in Settings › Printers (AirPrint).", $0) }
                        ?? L("You can now unplug USB and add it in Settings › Printers (AirPrint)."))
                HStack {
                    if let ip, let url = URL(string: "http://\(ip)") {
                        Button(L("Open Web Interface")) { NSWorkspace.shared.open(url) }
                    }
                    Button(L("Add Printer in macOS")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
        case .failed(let code, let status):
            let info = BrWLANReport.describe(code ?? -1)
            VStack(alignment: .leading, spacing: 8) {
                Banner(style: .error, title: code == nil ? L("The printer did not connect") : info.title,
                       message: code == nil
                        ? L("The printer did not confirm the connection (last status: %@). Check the password and the distance to the router.", status ?? L("no response"))
                        : info.advice)
                Text(L("Tip: choose “WPA2‑Personal (AES)” security and try again, or see the Reliability section."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
