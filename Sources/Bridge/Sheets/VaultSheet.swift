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
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Server", text: $server, prompt: Text("https://vault.example.com"))
                        .focused($focus, equals: .server)
                    TextField("Email", text: $email, prompt: Text("you@example.com"))
                    HStack {
                        Group {
                            if showPassword {
                                TextField("Master password", text: $password)
                            } else {
                                SecureField("Master password", text: $password)
                            }
                        }
                        .focused($focus, equals: .password)
                        Button(showPassword ? "Hide" : "Show", systemImage: showPassword ? "eye.slash" : "eye") {
                            showPassword.toggle()
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                    if provider != nil {
                        TextField("Two-step login code", text: $code, prompt: Text("123456"))
                            .focused($focus, equals: .code)
                    }
                } footer: {
                    Text("Your own server: an address like vault.example.com, https://example.com/vault behind a proxy, or http://192.168.1.10:8080 on your network.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Picker("Lock after", selection: $lockMinutes) {
                        Text("15 min").tag(UInt32(15))
                        Text("1 hour").tag(UInt32(60))
                        Text("4 hours").tag(UInt32(240))
                        Text("Never").tag(UInt32(0))
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("The master password and keys are never saved. Keys stay in memory while unlocked; locking, quitting or the idle time removes them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message {
                    Text(message.text).foregroundStyle(message.error ? Color.red : Color.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(busy)

            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(linked ? "Unlock" : "Link and Unlock", action: unlock)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy)
            }
            .padding()
        }
        .frame(width: 480)
        .navigationTitle(linked ? "Unlock Vaultwarden" : "Link Vaultwarden")
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
