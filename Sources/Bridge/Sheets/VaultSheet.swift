import BridgeCore
import BridgeSystem
import SwiftUI

/// Link or unlock Vaultwarden. Unlocking loads the vault's SSH keys into a private agent, in
/// memory only. The account signs in with its master password, or with the server's single
/// sign-on in the browser (and then the master password, which still encrypts the vault).
struct VaultSheet: View {
    enum SignIn: String {
        case password, sso
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    /// How this Mac signed in last time.
    @AppStorage("vaultSignIn") private var signIn: SignIn = .password
    /// A single sign-on that came back and waits for the master password or a two-step code.
    @State private var sso: VaultClient.SSOSignIn?
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
            confirm: signIn == .sso && sso == nil ? "Sign In with SSO…" : linked ? "Unlock" : "Link and Unlock",
            confirmDisabled: busy,
            onConfirm: unlock
        ) {
            Section {
                TextField("Server", text: $server, prompt: Text("vault.example.com"))
                    .focused($focus, equals: .server)
                    .onChange(of: server) { sso = nil }
                Picker("Sign in with", selection: $signIn) {
                    Text("Master password").tag(SignIn.password)
                    Text("Single sign-on").tag(SignIn.sso)
                }
                .pickerStyle(.segmented)
                .onChange(of: signIn) {
                    sso = nil
                    provider = nil
                    message = nil
                }
                if signIn == .password {
                    TextField("Email", text: $email, prompt: Text("you@example.com"))
                } else if sso != nil {
                    LabeledContent("Single sign-on") {
                        Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
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
                Text(signIn == .sso
                     ? "Your browser opens your server's sign-in page. The master password is still needed: it encrypts the vault, and never leaves this Mac."
                     : "Your own server: vault.example.com, https://example.com/vault behind a proxy, or http://192.168.1.10:8080 on your network.")
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
        if signIn == .sso {
            unlockWithSSO()
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

    /// Single sign-on: the browser first (unless it already came back), then the master password
    /// and, if the account has one, a two-step code.
    private func unlockWithSSO() {
        guard !password.isEmpty else {
            message = ("Enter the master password: it decrypts the vault after you sign in.", true)
            focus = .password
            return
        }
        if provider != nil, code.trimmingCharacters(in: .whitespaces).isEmpty {
            message = ("Enter the two-step login code.", true)
            return
        }
        let deviceID = store.profiles.vault?.deviceID ?? UUID().uuidString.lowercased()
        busy = true
        Task {
            defer { busy = false }
            do {
                let signedIn: VaultClient.SSOSignIn
                if let sso {
                    signedIn = sso
                } else {
                    message = ("Waiting for you to sign in in your browser…", false)
                    let open = openURL
                    signedIn = try await VaultClient.signInWithSSO(server: server) { url in open(url) }
                    sso = signedIn
                    NSApp.activate()
                }
                message = ("Unlocking…", false)
                let result = try await store.unlockVault(
                    sso: signedIn, password: password, deviceID: deviceID, lockMinutes: lockMinutes,
                    twoFactor: provider.map { ($0, code) })
                finished(result)
            } catch VaultClient.Failure.twoFactor(let providers) {
                if providers.contains(VaultClient.authenticator) {
                    provider = VaultClient.authenticator
                    message = ("Enter the code from your authenticator app.", false)
                    focus = .code
                } else {
                    sso = nil
                    message = ("This account's two-step login sends codes by email, which Bridge can't ask for after single sign-on yet. Add an authenticator app to the account, or sign in with the master password.", true)
                }
            } catch {
                // A code is good for one sign-in: start over in the browser next time.
                if !(error.localizedDescription == "Wrong master password.") { sso = nil }
                message = (error.localizedDescription, true)
            }
        }
    }

    private func finished(_ result: Store.UnlockResult) {
        var note = result.loaded == 1 ? "1 SSH key is ready." : "\(result.loaded) SSH keys are ready."
        if result.skipped > 0 { note += " \(result.skipped) organization items were skipped." }
        if !result.failures.isEmpty { note += " Not loaded: " + result.failures.joined(separator: "; ") }
        store.controllers.values.first { $0.window?.isKeyWindow == true }?.toast = "Vaultwarden unlocked. " + note
        password = ""
        dismiss()
    }
}
