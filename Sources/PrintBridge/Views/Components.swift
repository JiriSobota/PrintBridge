import SwiftUI
import BrotherKit

extension Color {
    static let brandA = Color(red: 0.23, green: 0.45, blue: 0.98)
    static let brandB = Color(red: 0.36, green: 0.80, blue: 0.86)
}

struct Card<Content: View>: View {
    var title: String?
    var symbol: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, symbol: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if title != nil || trailing != nil {
                HStack(spacing: 8) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.tint)
                    }
                    if let title {
                        Text(title).font(.headline)
                    }
                    Spacer()
                    trailing
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [.brandA, .brandB], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 24, weight: .bold, design: .rounded))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.bottom, 4)
    }
}

struct StatusPill: View {
    let text: String
    let color: Color
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol) } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .foregroundStyle(color)
        .background(color.opacity(0.13), in: Capsule())
    }
}

struct InfoRow: View {
    let label: String
    let value: String?
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 16)
            Text(value ?? "—")
                .font(monospaced ? .body.monospaced() : .body)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct Banner: View {
    enum Style { case info, success, warning, error }
    let style: Style
    let title: String
    var message: String? = nil

    var color: Color {
        switch style {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    var symbol: String {
        switch style {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                if let message {
                    Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(color.opacity(0.25)))
    }
}

struct SignalBars: View {
    let bars: Int
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i <= bars ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 4, height: CGFloat(5 + i * 3))
            }
        }
        .accessibilityLabel(L("Signal %d of 4", bars + 1))
    }
}

struct NotConnectedView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        ContentUnavailableView {
            Label(L("Printer not connected"), systemImage: "printer.dotmatrix")
        } description: {
            Text(L("Connect the printer with a USB cable or pick it on the network."))
        } actions: {
            Button(L("Go to Connection")) { model.section = .connect }
                .buttonStyle(.borderedProminent)
        }
    }
}

struct Page<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .padding(28)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
    }
}

/// Náhrada za `@State`: v SDK macOS 27 je `@State` makro, jehož plugin dodává jen plné Xcode.
/// Tento wrapper ukládá hodnotu do `SwiftUI.State`, takže se chová stejně a jde přeložit i s Command Line Tools.
@propertyWrapper
struct LocalState<Value>: DynamicProperty {
    private let storage: State<Value>

    init(wrappedValue: Value) {
        storage = State(initialValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}
