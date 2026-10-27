import Foundation

/// Logging in to Vaultwarden and reading the vault's SSH keys. Nothing is cached on disk and no
/// refresh token is kept: each unlock logs in again. A port of v1's vault client.
public enum VaultClient {
    public static let authenticator = 0
    public static let email = 1
    static let secureNote = 2
    static let sshKey = 5

    public struct Login: Sendable {
        public var server: String
        public var email: String
        public var password: String
        public var deviceID: String
        /// A two-step provider and its code.
        public var twoFactor: (provider: Int, code: String)?

        public init(server: String, email: String, password: String, deviceID: String, twoFactor: (provider: Int, code: String)? = nil) {
            self.server = server
            self.email = email
            self.password = password
            self.deviceID = deviceID
            self.twoFactor = twoFactor
        }
    }

    public enum Failure: Error, LocalizedError, Equatable {
        /// A two-step code is needed; the providers offered that this app supports.
        case twoFactor([Int])
        case rejected(String)
        case network(String)

        public var errorDescription: String? {
            switch self {
            case .twoFactor: "Enter your two-step login code."
            case .rejected(let message), .network(let message): message
            }
        }
    }

    /// An SSH private key from the vault.
    public struct Key: Sendable {
        public let id: String
        public let name: String
        public let privateKey: String
    }

    public struct Unlocked: Sendable {
        public var keys: [Key] = []
        /// Organization items, which need keys this client doesn't handle yet.
        public var skipped = 0
    }

    /// The server's base address as typed: `https://` is assumed when no scheme is given, and a
    /// path is kept (a server behind a reverse proxy at `https://example.com/vault`). Plain
    /// `http://` is only accepted on this Mac or the local network, where the master password's
    /// hash and the login token can't be read on the way across the internet.
    public static func serverURL(_ input: String) throws -> String {
        let input = input.trimmingCharacters(in: .whitespaces)
        let typed = input.contains("://") ? input : "https://" + input
        guard let components = URLComponents(string: typed), let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty, components.query == nil, components.fragment == nil,
              components.user == nil, components.password == nil, !input.contains(where: \.isWhitespace)
        else {
            throw Failure.rejected("Enter your Vaultwarden address, like vault.example.com.")
        }
        guard scheme == "https" || scheme == "http" else {
            throw Failure.rejected("The server address must start with https:// (or http://).")
        }
        guard scheme == "https" || isLocal(host) else {
            throw Failure.rejected("Use https:// for a server outside your network: over http:// your login could be read on the way.")
        }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let port = components.port.map { ":\($0)" } ?? ""
        let hostPart = host.contains(":") ? "[\(host)]" : host
        let server = "\(scheme)://\(hostPart)\(port)\(path)"
        guard URL(string: server + "/api") != nil else {
            throw Failure.rejected("Enter your Vaultwarden address, like vault.example.com.")
        }
        return server
    }

    /// This Mac, or an address on the local network (private ranges, `.local` names, names
    /// without a dot).
    static func isLocal(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".home.arpa") { return true }
        if host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fd") || host.hasPrefix("fc") { return host.contains(":") }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            switch (octets[0], octets[1]) {
            case (127, _), (10, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            case (100, 64...127): return true // carrier-grade NAT, as Tailscale uses
            default: return false
            }
        }
        return !host.contains(".") && !host.contains(":")
    }

    /// The address of an endpoint on the server.
    static func endpoint(_ server: String, _ path: String) throws -> URL {
        guard let url = URL(string: server + path) else { throw Failure.rejected("the server address is not valid") }
        return url
    }

    /// Follows no redirects: a server (or someone in between) mustn't send the login elsewhere.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// Log in and decrypt the vault's SSH keys.
    public static func unlock(_ login: Login) async throws -> Unlocked {
        let server = try serverURL(login.server)
        let kdf = try await prelogin(server: server, email: login.email)
        let masterKey = try VaultCrypto.masterKey(password: login.password, email: login.email, kdf: kdf)
        let hash = VaultCrypto.masterPasswordHash(masterKey: masterKey, password: login.password)
        let token = try await self.token(server: server, login: login, hash: hash)

        guard let wrapped = field(token, "Key") as? String else {
            throw Failure.rejected("the server did not send the account key")
        }
        let wrapping = wrapped.hasPrefix("0.")
            ? VaultCrypto.SymmetricKey.legacy(masterKey: masterKey)
            : VaultCrypto.SymmetricKey.stretched(masterKey: masterKey)
        let userKey: VaultCrypto.SymmetricKey
        do {
            userKey = try VaultCrypto.SymmetricKey(bytes: try wrapping.decrypt(wrapped))
        } catch let error as VaultCrypto.Failure {
            throw Failure.rejected(error.localizedDescription)
        }

        let access = field(token, "access_token") as? String ?? ""
        var request = URLRequest(url: try endpoint(server, "/api/sync?excludeDomains=true"))
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let sync = try await json(request, what: "sync response")
        return sshKeys(sync, userKey: userKey)
    }

    /// Ask the server to email a two-step code.
    public static func sendEmailCode(_ login: Login) async throws {
        let server = try serverURL(login.server)
        let kdf = try await prelogin(server: server, email: login.email)
        let masterKey = try VaultCrypto.masterKey(password: login.password, email: login.email, kdf: kdf)
        let hash = VaultCrypto.masterPasswordHash(masterKey: masterKey, password: login.password)
        var request = URLRequest(url: try endpoint(server, "/api/two-factor/send-email-login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": login.email.trimmingCharacters(in: .whitespaces),
            "masterPasswordHash": hash,
            "deviceIdentifier": login.deviceID,
        ])
        _ = try await send(request)
    }

    static func prelogin(server: String, email: String) async throws -> VaultCrypto.KDF {
        let body = try JSONSerialization.data(withJSONObject: ["email": email.trimmingCharacters(in: .whitespaces)])
        func request(_ path: String) throws -> URLRequest {
            var request = URLRequest(url: try endpoint(server, path))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            return request
        }
        // Newer servers answer on the identity endpoint, older Vaultwarden on the API one.
        let value: Any
        do {
            value = try await json(try request("/identity/accounts/prelogin"), what: "prelogin")
        } catch {
            value = try await json(try request("/api/accounts/prelogin"), what: "prelogin")
        }
        guard let kdf = kdf(from: value) else {
            throw Failure.rejected("the server sent key derivation settings this app does not know")
        }
        // Within Bitwarden's own limits: a server asking for one round would get a hash that is
        // cheap to crack, one asking for terabytes of memory would bring the Mac down.
        guard VaultCrypto.isAcceptable(kdf) else {
            throw Failure.rejected("the server asked for key derivation settings outside Bitwarden's limits")
        }
        return kdf
    }

    static func kdf(from value: Any) -> VaultCrypto.KDF? {
        func number(_ name: String) -> UInt32? { (field(value, name) as? NSNumber).map { $0.uint32Value } }
        switch number("kdf") {
        case 0:
            return number("kdfIterations").map { .pbkdf2(iterations: $0) }
        case 1:
            guard let iterations = number("kdfIterations"), let memory = number("kdfMemory"),
                  let parallelism = number("kdfParallelism") else { return nil }
            return .argon2id(iterations: iterations, memoryMiB: memory, parallelism: parallelism)
        default:
            return nil
        }
    }

    static func token(server: String, login: Login, hash: String) async throws -> Any {
        var form = [
            ("grant_type", "password"),
            ("username", login.email.trimmingCharacters(in: .whitespaces)),
            ("password", hash),
            ("scope", "api offline_access"),
            ("client_id", "cli"),
            ("deviceType", "24"),
            ("deviceName", "Bridge"),
            ("deviceIdentifier", login.deviceID),
        ]
        if let (provider, code) = login.twoFactor {
            form += [("twoFactorProvider", "\(provider)"), ("twoFactorToken", code.trimmingCharacters(in: .whitespaces)),
                     ("twoFactorRemember", "0")]
        }
        var request = URLRequest(url: try endpoint(server, "/identity/connect/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").utf8)

        let (data, status) = try await send(request, allowFailure: true)
        let value = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
        guard (200..<300).contains(status) else { throw loginError(value) }
        return value
    }

    /// Why a login was refused: a two-step code is needed, or the server's message.
    static func loginError(_ value: Any) -> Failure {
        var providers: [Int] = []
        if let object = field(value, "TwoFactorProviders2") as? [String: Any] {
            providers = object.keys.compactMap { Int($0) }
        } else if let list = field(value, "TwoFactorProviders") as? [Any] {
            providers = list.compactMap { ($0 as? NSNumber)?.intValue ?? ($0 as? String).flatMap { Int($0) } }
        }
        if !providers.isEmpty {
            let supported = providers.filter { $0 == authenticator || $0 == email }.sorted()
            guard !supported.isEmpty else {
                return .rejected("this account's two-step login method is not supported yet (use an authenticator app or email)")
            }
            return .twoFactor(supported)
        }
        let message = field(value, "error_description") as? String
            ?? (field(value, "ErrorModel").flatMap { field($0, "Message") } as? String)
            ?? "the server refused the login"
        return .rejected(message)
    }

    /// SSH keys in the sync data: SSH key items, and secure notes holding a private key.
    static func sshKeys(_ sync: Any, userKey: VaultCrypto.SymmetricKey) -> Unlocked {
        var unlocked = Unlocked()
        for cipher in field(sync, "ciphers") as? [Any] ?? [] {
            let kind = (field(cipher, "type") as? NSNumber)?.intValue ?? 0
            let deleted = field(cipher, "deletedDate").map { !($0 is NSNull) } ?? false
            guard kind == secureNote || kind == sshKey, !deleted else { continue }
            if let org = field(cipher, "organizationId"), !(org is NSNull) {
                unlocked.skipped += 1
                continue
            }
            // Items may carry their own key, encrypted with the user key.
            var key = userKey
            if let itemKey = field(cipher, "key") as? String {
                guard let bytes = try? userKey.decrypt(itemKey), let own = try? VaultCrypto.SymmetricKey(bytes: bytes) else { continue }
                key = own
            }
            func decrypt(_ value: Any?) -> String? {
                (value as? String).flatMap { try? key.decryptText($0) }
            }
            let privateKey = kind == sshKey
                ? decrypt(field(cipher, "sshKey").flatMap { field($0, "privateKey") })
                : decrypt(field(cipher, "notes")).flatMap { $0.contains("PRIVATE KEY-----") ? $0 : nil }
            guard let privateKey, let id = field(cipher, "id") as? String else { continue }
            unlocked.keys.append(Key(id: id, name: decrypt(field(cipher, "name")) ?? "SSH key", privateKey: privateKey))
        }
        return unlocked
    }

    /// A field by name, in camelCase or PascalCase (servers differ).
    static func field(_ value: Any, _ name: String) -> Any? {
        guard let object = value as? [String: Any] else { return nil }
        if let found = object[name] { return found }
        guard let first = name.first else { return nil }
        let flipped = (first.isLowercase ? first.uppercased() : first.lowercased()) + name.dropFirst()
        return object[flipped]
    }

    private static func json(_ request: URLRequest, what: String) async throws -> Any {
        let (data, _) = try await send(request)
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw Failure.network("unreadable \(what)")
        }
    }

    @discardableResult
    private static func send(_ request: URLRequest, allowFailure: Bool = false) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if !allowFailure, !(200..<300).contains(status) {
                throw Failure.network("the server answered \(status) for \(request.url?.path ?? "")")
            }
            return (data, status)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.network(error.localizedDescription)
        }
    }
}
