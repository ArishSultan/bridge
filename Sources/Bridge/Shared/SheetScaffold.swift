import SwiftUI

/// The frame every sheet uses: a grouped form under a toolbar with the title, Cancel, and the
/// confirming action, as macOS 26 draws them (Liquid Glass buttons in the sheet's title bar).
struct SheetScaffold<Content: View>: View {
    let title: String
    var subtitle: String?
    let confirm: String
    var confirmDisabled = false
    var destructive: (title: String, action: () -> Void)?
    let onConfirm: () -> Void
    @ViewBuilder let content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                content
                if let destructive {
                    Section {
                        Button(destructive.title, role: .destructive, action: destructive.action)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(title)
            .navigationSubtitle(subtitle ?? "")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirm, action: onConfirm)
                        .buttonStyle(.glassProminent)
                        .disabled(confirmDisabled)
                }
            }
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 320)
    }
}

/// An error or note under a form, in the form's own style.
struct FormMessage: View {
    let text: String
    var isError = true

    var body: some View {
        Section {
            Label(text, systemImage: isError ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(isError ? Color.red : Color.secondary)
        }
    }
}
