import SwiftUI
import UniformTypeIdentifiers
import BrotherKit

struct PrintView: View {
    @Environment(AppModel.self) private var model
    @LocalState private var dropTargeted = false
    @LocalState private var useUSB = false
    @LocalState private var removeCandidate: PrintQueue?

    var body: some View {
        @Bindable var model = model
        Page {
            PageHeader(title: L("Print"), subtitle: L("Pick files and print them – or print from anywhere with ⌘P."), symbol: "doc.on.doc")

            if let error = model.printError {
                Banner(style: .error, title: L("Something went wrong"), message: error)
            }
            if let message = model.printMessage {
                Banner(style: .success, title: L("Done"), message: message)
            }

            queueCard
            filesCard
            if !model.printItems.isEmpty { optionsCard }
            jobsCard
            integrationCard
        }
        .task { await model.refreshQueues() }
        .confirmationDialog(L("Remove the queue “%@”?", removeCandidate?.name ?? ""),
                            isPresented: Binding(get: { removeCandidate != nil }, set: { if !$0 { removeCandidate = nil } }),
                            titleVisibility: .visible) {
            Button(L("Remove"), role: .destructive) {
                if let q = removeCandidate { Task { await model.removeQueue(q.name) } }
                removeCandidate = nil
            }
            Button(L("Cancel"), role: .cancel) { removeCandidate = nil }
        } message: {
            Text(L("The printer disappears from the macOS printer list. You can add it again at any time."))
        }
    }

    // MARK: Fronta

    var queueCard: some View {
        Card(L("Printer in macOS"), symbol: "printer",
             trailing: AnyView(Button { Task { await model.refreshQueues() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help(L("Refresh")))) {
            if let queue = model.printBridgeQueue {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PrintSystem.queueDescription).font(.body.weight(.semibold))
                        Text("\(queue.state) · \(queue.connection)" + (queue.isDefault ? " · " + L("default printer") : ""))
                            .font(.caption).foregroundStyle(.secondary)
                        if let msg = queue.message {
                            Text(msg).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    if queue.state == L("Paused") {
                        Button(L("Resume Queue")) { Task { await model.resumeQueue(queue.name) } }
                    }
                    if !queue.isDefault {
                        Button(L("Make Default")) { Task { await model.setDefaultQueue(queue.name) } }
                    }
                }
            } else {
                Text(L("PrintBridge creates a reliable macOS print queue. Unlike the usual one it remembers the printer’s stable address instead of looking it up via Bonjour every time, and it retries jobs while the printer sleeps instead of dropping them. File › Print then works in every app."))
                    .font(.callout).foregroundStyle(.secondary)
            }

            HStack {
                Text(L("Connection")).fixedSize()
                Picker("", selection: $useUSB) {
                    Text(L("Wi‑Fi (recommended)")).tag(false)
                    Text(L("USB cable")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button {
                    Task { await model.setupQueue(preferUSB: useUSB, makeDefault: true) }
                } label: {
                    if model.isSettingUpQueue {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L("Setting up…")) }
                    } else {
                        Text(model.printBridgeQueue == nil ? L("Set Up Printer in macOS") : L("Set Up Again"))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isSettingUpQueue)
            }

            ForEach(model.fragileBrotherQueues) { queue in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("The queue “%@” looks the printer up via Bonjour", queue.name)).font(.callout.weight(.medium))
                        Text(L("Queues like this one report “The printer is not responding” when the printer sleeps. Once the new queue exists you can remove it."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.printBridgeQueue != nil {
                        Button(L("Remove"), role: .destructive) { removeCandidate = queue }.controlSize(.small)
                    }
                }
                .padding(10)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: Soubory

    var filesCard: some View {
        Card(L("Files to print"), symbol: "doc.on.doc",
             trailing: AnyView(Button(L("Add Files…")) { choose() }.controlSize(.small))) {
            if model.printItems.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc").font(.system(size: 34)).foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
                    Text(L("Drop files here")).font(.headline)
                    Text(L("PDF, images, text, Word, RTF, ODT, HTML… Others (Pages, Excel) open in their own app."))
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(L("Choose Files…")) { choose() }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                    .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4)))
            } else {
                VStack(spacing: 6) {
                    ForEach(model.printItems) { item in
                        HStack(spacing: 12) {
                            Group {
                                if let thumb = item.thumbnail {
                                    Image(nsImage: thumb).resizable().scaledToFit()
                                } else {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().scaledToFit()
                                }
                            }
                            .frame(width: 36, height: 46)
                            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).lineLimit(1).truncationMode(.middle)
                                Text(item.kindTitle).font(.caption)
                                    .foregroundStyle(item.kind == .unsupported ? Color.orange : Color.secondary)
                            }
                            Spacer()
                            Button { model.removePrintItem(item) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary).help(L("Remove"))
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { Task { @MainActor in model.addPrintFiles([url]) } }
                }
            }
            return true
        }
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = L("Add to Print")
        if panel.runModal() == .OK { model.addPrintFiles(panel.urls) }
    }

    // MARK: Možnosti

    var optionsCard: some View {
        @Bindable var model = model
        return Card(L("Print options"), symbol: "slider.horizontal.3") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text(L("Printer")).foregroundStyle(.secondary)
                    Picker("", selection: $model.selectedQueue) {
                        ForEach(model.queues) { q in
                            Text(q.isPrintBridge ? PrintSystem.queueDescription : q.name).tag(Optional(q.name))
                        }
                    }
                    .labelsHidden().frame(maxWidth: 320, alignment: .leading)
                }
                GridRow {
                    Text(L("Copies")).foregroundStyle(.secondary)
                    Stepper("\(model.printOptions.copies)", value: $model.printOptions.copies, in: 1...99)
                        .frame(maxWidth: 120, alignment: .leading)
                }
                GridRow {
                    Text(L("Pages")).foregroundStyle(.secondary)
                    TextField(L("All (or e.g. 1-3,5)"), text: $model.printOptions.pageRange)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                }
                GridRow {
                    Text(L("Two-sided")).foregroundStyle(.secondary)
                    Picker("", selection: $model.printOptions.sides) {
                        ForEach(PrintOptions.Sides.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(maxWidth: 240, alignment: .leading)
                }
                GridRow {
                    Text(L("Quality")).foregroundStyle(.secondary)
                    Picker("", selection: $model.printOptions.quality) {
                        ForEach(PrintOptions.Quality.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
                }
                GridRow {
                    Text("")
                    Toggle(L("Fit to page"), isOn: $model.printOptions.fitToPage)
                }
            }
            if let error = model.printOptions.validationError {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.callout)
            }
            HStack {
                Text(L("Duplex printing is automatic on supported models.")).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await model.printAll() }
                } label: {
                    if model.isPrinting {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L("Sending…")) }
                    } else {
                        Label(L("Print (%d)", model.printItems.count), systemImage: "printer.fill").padding(.horizontal, 6)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut("p", modifiers: .command)
                .disabled(model.isPrinting || model.selectedQueue == nil || model.printOptions.validationError != nil)
            }
        }
    }

    // MARK: Úlohy

    var jobsCard: some View {
        Card(L("Print jobs"), symbol: "list.bullet") {
            if model.jobs.isEmpty {
                Text(L("No pending jobs.")).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(model.jobs) { job in
                        HStack {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(job.id).font(.body.monospaced())
                                Text(job.status ?? job.date).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(L("Cancel")) { Task { await model.cancelJob(job.id) } }.controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    // MARK: Integrace

    var integrationCard: some View {
        Card(L("Print from anywhere"), symbol: "square.and.arrow.up") {
            VStack(alignment: .leading, spacing: 8) {
                IntegrationRow(symbol: "command", text: L("In any app: File › Print (⌘P) → “%@”.", PrintSystem.queueDescription))
                IntegrationRow(symbol: "contextualmenu.and.cursorarrow", text: L("In Finder, right-click a file › Services › Print with PrintBridge."))
                IntegrationRow(symbol: "arrow.up.forward.app", text: L("In Finder use Open With › PrintBridge, or drop a file on the Dock icon."))
                IntegrationRow(symbol: "square.and.arrow.up", text: L("Share › PrintBridge in apps that support sharing."))
            }
            Divider()
            Toggle(L("Open PrintBridge at login"), isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
        }
    }
}

struct IntegrationRow: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 18)
            Text(text).font(.callout)
        }
    }
}
