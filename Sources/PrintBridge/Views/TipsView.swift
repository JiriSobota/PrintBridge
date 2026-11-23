import BrotherKit
import SwiftUI

struct TipsView: View {
    struct Tip: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let text: String
    }

    let tips: [Tip] = [
        Tip(symbol: "arrow.down.circle", title: L("Update the firmware"),
            text: L("Newer Brother firmware fixes Wi‑Fi drop-outs and security bugs. Check it in the Firmware section.")),
        Tip(symbol: "dot.radiowaves.left.and.right", title: L("2.4 GHz band"),
            text: L("These printers only support 2.4 GHz (802.11 b/g/n). Your router must broadcast this band. A shared name for 2.4 and 5 GHz is usually fine.")),
        Tip(symbol: "lock.shield", title: L("WPA2 instead of WPA3-only"),
            text: L("The printer does not support WPA3. Set the router to “WPA2‑Personal (AES)” or the mixed “WPA2/WPA3” mode.")),
        Tip(symbol: "number", title: L("Fixed channel 1, 6 or 11"),
            text: L("Automatic channel switching on the router can disconnect the printer. A fixed channel and 20 MHz width on 2.4 GHz help stability.")),
        Tip(symbol: "pin", title: L("Reserve the IP address"),
            text: L("Give the printer a fixed address on your router (DHCP reservation by MAC). Your Mac will always find it in the same place.")),
        Tip(symbol: "moon.zzz", title: L("Deep sleep"),
            text: L("If the printer does not respond after waking up, adjust Sleep Time and Auto Power Off in the printer’s web interface (General › Sleep Time).")),
        Tip(symbol: "wifi.router", title: L("Turn off Wi‑Fi Direct"),
            text: L("If you don’t use Wi‑Fi Direct, turn it off – the printer then doesn’t have to serve two wireless links at once.")),
        Tip(symbol: "printer", title: L("AirPrint instead of old drivers"),
            text: L("Add the printer in macOS via AirPrint (Settings › Printers & Scanners). No Brother driver is needed.")),
        Tip(symbol: "location", title: L("Placement"),
            text: L("Metal cabinets, microwaves and walls weaken the signal. Your network should show at least 2 bars in the network scan.")),
    ]

    var body: some View {
        Page {
            PageHeader(title: L("Reliability"), subtitle: L("What helps most to keep the printer on Wi‑Fi."), symbol: "checkmark.shield")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                ForEach(tips) { tip in
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: tip.symbol)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 32, height: 32)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        Text(tip.title).font(.headline)
                        Text(tip.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.5)))
                }
            }
        }
    }
}
