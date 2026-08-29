#if os(macOS)
import SwiftUI

/// Shared chrome for Conduit sheets: always-visible **Close** on the top-left
/// so operators are not left hunting for Esc.
struct ConduitSheetHeader<Trailing: View>: View {
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    /// Prefer this when the sheet is presented via a model flag rather than
    /// `dismiss` environment.
    var onClose: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        onClose: (() -> Void)? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.onClose = onClose
        self.trailing = trailing
    }

    private var palette: ConduitPalette {
        themeStore.palette(for: colorScheme)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: close) {
                Label("Close", systemImage: "xmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(palette.dim)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close")
            .help("Close this panel (Esc also works)")

            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(palette.accent)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(palette.text)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(palette.dim)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(palette.surface)
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}
#endif
