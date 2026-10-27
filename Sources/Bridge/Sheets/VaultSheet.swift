import BridgeCore
import BridgeSystem
import SwiftUI

/// Link or unlock Vaultwarden. Unlocking loads the vault's SSH keys into a private agent, in
/// memory only.
struct VaultSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var email = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var code = ""
    @State private var provider: Int?
    @State private var lockMinutes: UInt32 = 60
    @State private var busy = false
    @State private var message: (text: String, error: Bool)?
    @FocusState private var focus: Field?

    enum Field { case server, password, code }

    private var store: Store { .shared }
    private var linked: Bool { store.profiles.vault != nil }

    var body: some View {
        SheetScaffold(
            title: linked ? "Unlock Vaultwarden" : "Link Vaultwarden",
            confirm: linked ? "Unlock" : "Link and Unlock",
            confirmDisabled: busy,
            onConfirm: unlock
        ) {
            Section {
                TextField("Server", text: $server, prompt: Text("vault.example.com"))
                    .focused($focus, equals: .server)
                TextField("Email", text: $email, prompt: Text("you@example.com"))
                LabeledContent("Master password") {
                    HStack {
                        Group {
                            if showPassword {
                                TextField("Master password", text: $password)
                            } else {
                                SecureField("Master password", text: $password)
                            }
                        }
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .focused($focus, equals: .password)
                        Button(showPassword ? "Hide" : "Show", systemImage: showPassword ? "eye.slash" : "eye") {
                            showPassword.toggle()
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
                if provider != nil {
                    TextField("Two-step code", text: $code, prompt: Text("123456"))
                        .focused($focus, equals: .code)
                }
            } footer: {
                Text("Your own server: vault.example.com, https://example.com/vault behind a proxy, or http://192.168.1.10:8080 on your network.")
            }
            Section {
                Picker("Lock after", selection: $lockMinutes) {
                    Text("15 minutes").tag(UInt32(15))
                    Text("1 hour").tag(UInt32(60))
                    Text("4 hours").tag(UInt32(240))
                    Text("Never").tag(UInt32(0))
                }
            } footer: {
                Text("The master password and keys are never saved. Keys stay in memory while unlocked.")
            }
            if busy {
                Section {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(message?.text ?? "Unlocking…").foregroundStyle(.secondary)
                    }
                }
            } else if let message {
                FormMessage(text: message.text, isError: message.error)
            }
        }
        .disabled(busy)
        .onAppear {
            if let account = store.profiles.vault {
                server = account.server
                email = account.email
                lockMinutes = account.lockMinutes
                focus = .password
            } else {
                focus = .server
            }
        }
    }

    private func unlock() {
        do {
            _ = try VaultClient.serverURL(server)
        } catch {
            message = (error.localizedDescription, true)
            return
        }
        guard email.contains("@") else { message = ("Enter the account's email address.", true); return }
        guard !password.isEmpty else { message = ("Enter the master password.", true); return }
        if provider != nil, code.trimmingCharacters(in: .whitespaces).isEmpty {
            message = ("Enter the two-step login code.", true)
            return
        }

        let login = VaultClient.Login(
            server: server, email: email, password: password,
            deviceID: store.profiles.vault?.deviceID ?? UUID().uuidString.lowercased(),
            twoFactor: provider.map { ($0, code) })
        busy = true
        message = ("Unlocking…", false)
        Task {
            defer { busy = false }
            do {
                let result = try await store.unlockVault(login, lockMinutes: lockMinutes)
                var note = result.loaded == 1 ? "1 SSH key is ready." : "\(result.loaded) SSH keys are ready."
                if result.skipped > 0 { note += " \(result.skipped) organization items were skipped." }
                if !result.failures.isEmpty { note += " Not loaded: " + result.failures.joined(separator: "; ") }
                store.controllers.values.first { $0.window?.isKeyWindow == true }?.toast = "Vaultwarden unlocked. " + note
                password = ""
                dismiss()
            } catch VaultClient.Failure.twoFactor(let providers) {
                // An authenticator app if offered, else email (which sends the code now).
                if providers.contains(VaultClient.authenticator) {
                    provider = VaultClient.authenticator
                    message = ("Enter the code from your authenticator app.", false)
                } else {
                    provider = VaultClient.email
                    message = ("The server is emailing you a code; enter it here.", false)
                    try? await VaultClient.sendEmailCode(login)
                }
                focus = .code
            } catch {
                message = (error.localizedDescription, true)
            }
        }
    }
}
