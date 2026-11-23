import SwiftUI
import BrotherKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Picker(L("Language"), selection: Binding(
                    get: { model.languagePreference ?? "system" },
                    set: { model.setLanguage($0 == "system" ? nil : $0) }
                )) {
                    Text(L("Same as system")).tag("system")
                    Divider()
                    ForEach(L10n.languages) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                Text(L("Menus provided by macOS switch after the app restarts."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(L("Open PrintBridge at login"), isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
        .id(model.languageRevision)
    }
}
