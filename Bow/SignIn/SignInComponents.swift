import SwiftUI

// Building blocks for the sign-in screens: a consistent header, grouped fields with leading icons, full-width
// buttons that show their own spinner, and an inline error banner.

struct Header: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 76, height: 76)
                .background(Color.accentColor.gradient, in: .rect(cornerRadius: 20))
                .shadow(color: .accentColor.opacity(0.25), radius: 12, y: 6)
                .accessibilityHidden(true)
            Text(title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 12)
    }
}

/// One text field with a leading icon. Inside an `InputGroup` the rows share a card, separated by dividers.
struct InputField<Field: View>: View {
    let symbol: String
    @ViewBuilder let field: Field

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            field
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 50)
        .background(.background, in: .rect(cornerRadius: 12))
    }
}

/// Stacks fields into one card, like the system's grouped lists.
struct InputGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows.indices, id: \.self) { index in
                    rows[index]
                    if index < rows.count - 1 {
                        Divider().padding(.leading, 48)
                    }
                }
            }
        }
        .background(.background, in: .rect(cornerRadius: 12))
    }
}

struct PrimaryButton: View {
    let title: String
    var symbol: String?
    var isWorking = false
    let action: () -> Void

    init(_ title: String, symbol: String? = nil, isWorking: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.isWorking = isWorking
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ButtonLabel(title: title, symbol: symbol, isWorking: isWorking)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .controlSize(.large)
    }
}

struct SecondaryButton: View {
    let title: String
    var symbol: String?
    var isWorking = false
    let action: () -> Void

    init(_ title: String, symbol: String? = nil, isWorking: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.isWorking = isWorking
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ButtonLabel(title: title, symbol: symbol, isWorking: isWorking)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .controlSize(.large)
    }
}

private struct ButtonLabel: View {
    let title: String
    let symbol: String?
    let isWorking: Bool

    var body: some View {
        ZStack {
            // The title keeps its space while the spinner shows, so the button doesn't change size.
            Group {
                if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
            }
            .opacity(isWorking ? 0 : 1)
            if isWorking { ProgressView() }
        }
        .font(.body.weight(.semibold))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityLabel(isWorking ? "\(title), in progress" : title)
    }
}

struct OrDivider: View {
    var body: some View {
        HStack(spacing: 12) {
            line
            Text("or")
                .font(.footnote)
                .foregroundStyle(.secondary)
            line
        }
        .accessibilityHidden(true)
    }

    private var line: some View {
        Rectangle().fill(.separator).frame(height: 1)
    }
}

struct ErrorBanner: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
        .padding(14)
        .background(.red.opacity(0.1), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
