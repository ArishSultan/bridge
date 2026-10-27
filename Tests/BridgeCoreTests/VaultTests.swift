import Foundation
import Testing
@testable import BridgeSystem

/// The same vectors v1's vault tests use, so both versions agree.
struct VaultCryptoTests {
    static let password = "correct horse battery staple"
    static let masterKey = "52ce2d33e007a7c15b3e3083c551fcff97da83045fa80cc6bbbd2cbc52c6f084"
    static let userKey = "2.ZGVmZ2hpamtsbW5vcHFycw==|3LHLE825a4QlhMUcSQPe0yUMM1sLIGKAKZDLOwK6xZCgqklxgQPFFZ3DCsPpx7LipJvkOJhWSL6BoN9go/T7KPFB+2HN2cUmEEvBkdjKpEs=|JIei8OKL+C3GLVk0xtCLJ7EzOObv5I+YB8YBmqD4jM4="
    static let message = "2.yMnKy8zNzs/Q0dLT1NXW1w==|/5LxAPiNDQuhpSSF011GkNR7jGn1cvh22qgGyNHoXwQUTKwdQza+eEnHzLGYqVB5|EJyRbCgIBwK9zC0UYfHU7W5RHA/OqfgMzz8anHUrX68="

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    @Test func derivesTheMasterKeyAndLoginHash() throws {
        let key = try VaultCrypto.masterKey(password: Self.password, email: "  User@Example.com ", kdf: .pbkdf2(iterations: 5000))
        #expect(hex(key) == Self.masterKey)
        #expect(VaultCrypto.masterPasswordHash(masterKey: key, password: Self.password) == "0FMeontUyfpu9Ga/DvERL9LMAXg9KB82VK6UqHdnKko=")
        #expect(throws: VaultCrypto.Failure.badKDF) {
            try VaultCrypto.masterKey(password: "x", email: "a", kdf: .pbkdf2(iterations: 0))
        }
    }

    @Test func stretchesAndDecryptsTheUserKeyThenItems() throws {
        let key = try VaultCrypto.masterKey(password: Self.password, email: "user@example.com", kdf: .pbkdf2(iterations: 5000))
        let stretched = VaultCrypto.SymmetricKey.stretched(masterKey: key)
        #expect(hex(stretched.encryption) == "83b79d8c4f57f2e6ab04e4427c3fcc0d9bdeff981254a535a3df2bd2a4df84a7")
        let userKeyBytes = try stretched.decrypt(Self.userKey)
        #expect(userKeyBytes == Data(0..<64))
        let userKey = try VaultCrypto.SymmetricKey(bytes: userKeyBytes)
        #expect(try userKey.decryptText(Self.message) == "-----BEGIN OPENSSH PRIVATE KEY-----\ntest\n")
    }

    @Test func refusesChangedDataAndWrongKeys() throws {
        let userKey = try VaultCrypto.SymmetricKey(bytes: Data(0..<64))
        let parts = Self.message.split(separator: "|").map(String.init)
        var data = Data(base64Encoded: parts[1])!
        data[0] ^= 1
        let tampered = "\(parts[0])|\(data.base64EncodedString())|\(parts[2])"
        #expect(throws: VaultCrypto.Failure.tampered) { try userKey.decrypt(tampered) }
        let wrong = try VaultCrypto.SymmetricKey(bytes: Data(repeating: 7, count: 64))
        #expect(throws: VaultCrypto.Failure.tampered) { try wrong.decrypt(Self.message) }
        #expect(throws: VaultCrypto.Failure.malformed) { try userKey.decrypt("4.rsa-is-not-handled") }
    }

    /// RFC 9106, section 5.3: the Argon2id test vector.
    @Test func argon2idMatchesRFC9106() throws {
        let tag = try VaultCrypto.argon2id(
            password: Data(repeating: 0x01, count: 32), salt: Data(repeating: 0x02, count: 16),
            iterations: 3, memoryKiB: 32, parallelism: 4,
            secret: Data(repeating: 0x03, count: 8), associated: Data(repeating: 0x04, count: 12))
        #expect(hex(tag) == "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659")
    }

    @Test func argon2UsesTheHashedEmailAndMebibytes() throws {
        let kdf = VaultCrypto.KDF.argon2id(iterations: 2, memoryMiB: 16, parallelism: 1)
        let a = try VaultCrypto.masterKey(password: Self.password, email: "User@Example.com", kdf: kdf)
        let b = try VaultCrypto.masterKey(password: Self.password, email: "user@example.com", kdf: kdf)
        #expect(a == b)
        #expect(hex(a) != Self.masterKey)
        #expect(throws: VaultCrypto.Failure.badKDF) {
            try VaultCrypto.masterKey(password: "x", email: "a", kdf: .argon2id(iterations: 0, memoryMiB: 1, parallelism: 1))
        }
    }

    @Test func refusesKDFOutsideBitwardensLimits() {
        // A server can't make the login hash cheap to crack, or ask for terabytes of memory.
        #expect(!VaultCrypto.isAcceptable(.pbkdf2(iterations: 1)))
        #expect(VaultCrypto.isAcceptable(.pbkdf2(iterations: 600_000)))
        #expect(!VaultCrypto.isAcceptable(.pbkdf2(iterations: .max)))
        #expect(!VaultCrypto.isAcceptable(.argon2id(iterations: 3, memoryMiB: 4_000_000, parallelism: 4)))
        #expect(!VaultCrypto.isAcceptable(.argon2id(iterations: 1, memoryMiB: 64, parallelism: 4)))
        #expect(VaultCrypto.isAcceptable(.argon2id(iterations: 3, memoryMiB: 64, parallelism: 4)))
    }
}

struct VaultClientTests {
    @Test func normalizesServerAddresses() throws {
        #expect(try VaultClient.serverURL("vault.example.com/") == "https://vault.example.com")
        #expect(try VaultClient.serverURL("https://example.com/vault/") == "https://example.com/vault")
        #expect(try VaultClient.serverURL(" http://192.168.1.10:8080 ") == "http://192.168.1.10:8080")
        #expect(try VaultClient.serverURL("http://localhost:8000/") == "http://localhost:8000")
        #expect(try VaultClient.serverURL("http://nas.local") == "http://nas.local")
        #expect(throws: VaultClient.Failure.self) { try VaultClient.serverURL("ftp://x") }
        #expect(throws: VaultClient.Failure.self) { try VaultClient.serverURL("") }
        // Plain http across the internet would expose the login.
        #expect(throws: VaultClient.Failure.self) { try VaultClient.serverURL("http://vault.example.com") }
        // Addresses that used to crash the app.
        for bad in ["https://[abc/x", "https://a:b:c/x", "https://exa%mple.com/x", "https://a:-1/x", "https://a b"] {
            #expect(throws: VaultClient.Failure.self) { try VaultClient.serverURL(bad) }
        }
    }

    @Test func readsKDFInEitherCase() {
        #expect(VaultClient.kdf(from: ["kdf": 0, "kdfIterations": 600000]) == .pbkdf2(iterations: 600000))
        #expect(VaultClient.kdf(from: ["Kdf": 1, "KdfIterations": 3, "KdfMemory": 64, "KdfParallelism": 4])
            == .argon2id(iterations: 3, memoryMiB: 64, parallelism: 4))
        #expect(VaultClient.kdf(from: ["kdf": 9]) == nil)
    }

    @Test func explainsRefusedLogins() {
        #expect(VaultClient.loginError(["TwoFactorProviders2": ["1": [:], "0": [:]]]) == .twoFactor([0, 1]))
        #expect(VaultClient.loginError(["TwoFactorProviders": ["3"]]) == .rejected(
            "this account's two-step login method is not supported yet (use an authenticator app or email)"))
        #expect(VaultClient.loginError(["error_description": "invalid_username_or_password"]) == .rejected("invalid_username_or_password"))
        #expect(VaultClient.loginError(["ErrorModel": ["Message": "Locked"]]) == .rejected("Locked"))
    }

    @Test func findsSSHKeysInSyncData() throws {
        let userKey = try VaultCrypto.SymmetricKey(bytes: Data(0..<64))
        let key = VaultCryptoTests.message // decrypts to an OpenSSH private key
        let sync: [String: Any] = ["Ciphers": [
            ["id": "a", "type": 5, "sshKey": ["privateKey": key]],
            ["id": "b", "type": 2, "notes": key, "deletedDate": "2026-01-01"],
            ["id": "c", "type": 2, "notes": key, "organizationId": "org"],
            ["id": "d", "type": 1, "notes": key],
            ["id": "e", "type": 2, "notes": key, "name": "not-encrypted"],
        ]]
        let unlocked = VaultClient.sshKeys(sync, userKey: userKey)
        #expect(unlocked.keys.map(\.id) == ["a", "e"])
        #expect(unlocked.keys.first?.name == "SSH key")
        #expect(unlocked.skipped == 1)
    }
}

struct VaultAgentTests {
    @Test func loadsAKeyAndWritesItsPublicHalf() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agent-test-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-q", "-t", "ed25519", "-N", "", "-C", "bridge-test", "-f", dir.appendingPathComponent("k").path]
        try keygen.run()
        keygen.waitUntilExit()
        let privateKey = try String(contentsOf: dir.appendingPathComponent("k"), encoding: .utf8)
        let expected = try String(contentsOf: dir.appendingPathComponent("k.pub"), encoding: .utf8)

        let agent = try VaultAgent(helper: nil)
        defer { agent.stop() }
        let path = try agent.add(id: "item/1", privateKey: privateKey)
        #expect(path.hasSuffix("/item_1.pub"))
        let publicHalf = try String(contentsOfFile: path, encoding: .utf8)
        #expect(publicHalf.split(separator: " ").prefix(2) == expected.split(separator: " ").prefix(2))
        // The same key twice is refused.
        #expect(throws: VaultClient.Failure.self) { try agent.add(id: "again", privateKey: privateKey) }
        agent.stop()
        #expect(!FileManager.default.fileExists(atPath: agent.directory.path))
    }
}
