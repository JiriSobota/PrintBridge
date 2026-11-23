import SwiftUI
import UniformTypeIdentifiers
import BrotherKit

struct FirmwareView: View {
    @Environment(AppModel.self) private var model
    @LocalState private var pendingUpload: URL?
    @LocalState private var acknowledged = false

    var body: some View {
        if !model.connection.isConnected {
            NotConnectedView()
        } else {
            Page {
                PageHeader(title: "Firmware", subtitle: L("Official updates straight from Brother’s server."), symbol: "arrow.down.circle")

                if let error = model.lastError {
                    Banner(style: .error, title: L("Error"), message: error)
                }
                if let message = model.uploadMessage {
                    Banner(style: .success, title: L("Firmware sent"), message: message)
                }

                currentCard
                updatesCard
                manualCard
                modCard
            }
            .sheet(item: $pendingUpload) { file in
                UploadConfirmSheet(file: file, acknowledged: $acknowledged) {
                    pendingUpload = nil
                    Task { await model.upload(file: file) }
                } onCancel: {
                    pendingUpload = nil
                }
            }
        }
    }

    var currentCard: some View {
        Card(L("Installed version"), symbol: "cpu",
             trailing: AnyView(Button(L("Read from printer")) { Task { await model.readFirmware() } }
                .controlSize(.small).disabled(model.activity != nil))) {
            if let fw = model.firmware {
                VStack(spacing: 8) {
                    InfoRow(label: "Model", value: fw.model)
                    InfoRow(label: "SPEC", value: fw.spec, monospaced: true)
                    ForEach(fw.parts) { part in
                        InfoRow(label: L("Firmware %@", part.id), value: part.version, monospaced: true)
                    }
                }
            } else {
                Text(L("Read via PJL over USB and via SNMP over the network (the same data Brother’s Firmware Update Tool uses)."))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    var updatesCard: some View {
        Card(L("Updates"), symbol: "arrow.triangle.2.circlepath",
             trailing: AnyView(Button(L("Check")) { Task { await model.checkFirmware() } }
                .controlSize(.small)
                .disabled(model.firmware == nil || model.activity != nil))) {
            if model.firmware == nil {
                Text(L("Read the installed version first.")).foregroundStyle(.secondary)
            } else if model.firmwareChecks.isEmpty {
                Text(L("Only the model, SPEC and firmware version are sent to Brother – no serial number or other data."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(model.firmware?.parts ?? []) { part in
                        if let check = model.firmwareChecks[part.id] {
                            UpdateRow(part: part, check: check)
                        }
                    }
                }
            }
            if let progress = model.downloadProgress {
                ProgressView(L("Downloading firmware…"), value: progress)
            }
            if let progress = model.uploadProgress {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(L("Uploading to the printer – do not turn it off!"), value: progress)
                    Text("\(Int(progress * 100)) %").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
    }

    var manualCard: some View {
        Card(L("Custom file"), symbol: "doc.badge.arrow.up") {
            Text(L("Downloaded the firmware elsewhere (a Brother .djf file)? You can send it to the printer manually."))
                .font(.callout).foregroundStyle(.secondary)
            Button(L("Choose File…")) {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [UTType(filenameExtension: "djf") ?? .data, .data]
                panel.allowsOtherFileTypes = true
                if panel.runModal() == .OK, let url = panel.url {
                    acknowledged = false
                    pendingUpload = url
                }
            }
            .disabled(model.activity != nil)
        }
    }

    var modCard: some View {
        Card(L("Modified firmware?"), symbol: "exclamationmark.shield") {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("There is no public “.bin” firmware that could be safely modified. Brother distributes firmware only through its server as an encrypted, signed .djf file – the printer rejects modified files, and if it accepted one it could be bricked for good."))
                Text(L("So Wi‑Fi reliability is improved differently: with the latest official firmware (Brother fixes Wi‑Fi bugs and security holes in it) and the right router settings – see Reliability."))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

struct UpdateRow: View {
    @Environment(AppModel.self) private var model
    let part: FirmwarePart
    let check: FirmwareCheck
    @LocalState private var confirmFile: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            switch check {
            case .upToDate:
                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green).font(.title3)
                VStack(alignment: .leading) {
                    Text(L("%@: up to date", part.id)).font(.body.weight(.medium))
                    Text(L("Version %@ is the latest.", part.version)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            case .update(let version, let url):
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.tint).font(.title3)
                VStack(alignment: .leading) {
                    Text(L("%@: %@ available", part.id, version)).font(.body.weight(.medium))
                    Text(L("Installed %@", part.version)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let file = model.downloadedFiles[part.id] {
                    Button(L("Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    Button(L("Upload to printer")) { confirmFile = file }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.activity != nil)
                } else {
                    Button(L("Download")) { Task { await model.download(part: part.id, version: version, url: url) } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.downloadProgress != nil)
                }
            case .unknown(let message):
                Image(systemName: "questionmark.circle.fill").foregroundStyle(.orange).font(.title3)
                VStack(alignment: .leading) {
                    Text(L("%@: cannot be determined", part.id)).font(.body.weight(.medium))
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .sheet(item: $confirmFile) { file in
            UploadConfirmSheet(file: file, acknowledged: .constant(false)) {
                confirmFile = nil
                Task { await model.upload(file: file) }
            } onCancel: { confirmFile = nil }
        }
    }
}

struct UploadConfirmSheet: View {
    let file: URL
    @Binding var acknowledged: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @LocalState private var checks = [false, false, false]

    var looksValid: Bool {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
        defer { try? handle.close() }
        return BrotherFirmwareService.looksLikeFirmware(handle.readData(ofLength: 64))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L("Upload firmware to the printer"), systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.orange)
            Text(file.lastPathComponent).font(.body.monospaced())
            if !looksValid {
                Banner(style: .warning, title: L("The file does not look like Brother firmware"),
                       message: L("It has no PJL header. If you are not sure, do not upload it."))
            }
            VStack(alignment: .leading, spacing: 8) {
                Toggle(L("The printer is on, idle, and I won’t turn it off"), isOn: $checks[0])
                Toggle(L("I won’t disconnect USB or the network until the printer restarts by itself"), isOn: $checks[1])
                Toggle(L("I understand the update cannot be undone"), isOn: $checks[2])
            }
            .toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(L("Upload Firmware"), action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .disabled(!checks.allSatisfy { $0 })
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
