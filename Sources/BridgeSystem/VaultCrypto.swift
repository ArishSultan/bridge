import CArgon2
import CommonCrypto
import CryptoKit
import Foundation

/// Bitwarden's client-side cryptography, as Vaultwarden expects it: the master key from the
/// master password, the login hash, the stretched key that unwraps the account key, and
/// decrypting `EncString`s. A port of v1's `bridge-vault` crypto.
public enum VaultCrypto {
    public enum Failure: Error, Equatable, LocalizedError {
        case badKDF
        case malformed
        case tampered
        case decrypt

        public var errorDescription: String? {
            switch self {
            case .badKDF: "unsupported key derivation settings"
            case .malformed: "unreadable encrypted data"
            case .tampered: "wrong master password, or the data was changed"
            case .decrypt: "could not decrypt"
            }
        }
    }

    public enum KDF: Equatable, Sendable {
        case pbkdf2(iterations: UInt32)
        case argon2id(iterations: UInt32, memoryMiB: UInt32, parallelism: UInt32)
    }

    /// Whether key derivation settings are within the limits Bitwarden's own clients accept.
    public static func isAcceptable(_ kdf: KDF) -> Bool {
        switch kdf {
        case .pbkdf2(let iterations):
            (5_000...2_000_000).contains(iterations)
        case .argon2id(let iterations, let memoryMiB, let parallelism):
            (2...10).contains(iterations) && (16...1024).contains(memoryMiB) && (1...16).contains(parallelism)
        }
    }

    /// The master key: PBKDF2-SHA256 over the password salted with the email, or Argon2id
    /// salted with the email's SHA-256. The email is trimmed and lowercased first.
    public static func masterKey(password: String, email: String, kdf: KDF) throws -> Data {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch kdf {
        case .pbkdf2(let iterations):
            guard isAcceptable(kdf) else { throw Failure.badKDF }
            return pbkdf2(password: Data(password.utf8), salt: Data(email.utf8), iterations: iterations)
        case .argon2id(let iterations, let memoryMiB, let parallelism):
            guard isAcceptable(kdf) else { throw Failure.badKDF }
            let salt = Data(SHA256.hash(data: Data(email.utf8)))
            return try argon2id(password: Data(password.utf8), salt: salt, iterations: iterations,
                                memoryKiB: memoryMiB * 1024, parallelism: parallelism)
        }
    }

    /// What the server checks at login: PBKDF2(master key, salt: password, 1 round), base64.
    public static func masterPasswordHash(masterKey: Data, password: String) -> String {
        pbkdf2(password: masterKey, salt: Data(password.utf8), iterations: 1).base64EncodedString()
    }

    static func pbkdf2(password: Data, salt: Data, iterations: UInt32) -> Data {
        var out = Data(count: 32)
        let status = out.withUnsafeMutableBytes { outBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                        outBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        precondition(status == kCCSuccess)
        return out
    }

    /// Argon2id (version 0x13), 32 bytes, with an optional secret and associated data (only the
    /// test vectors use those).
    static func argon2id(password: Data, salt: Data, iterations: UInt32, memoryKiB: UInt32, parallelism: UInt32,
                         secret: Data = Data(), associated: Data = Data(), length: Int = 32) throws -> Data {
        var out = Data(count: length)
        var pwd = password, slt = salt, sec = secret, ad = associated
        let status = out.withUnsafeMutableBytes { outBytes in
            pwd.withUnsafeMutableBytes { pwdBytes in
                slt.withUnsafeMutableBytes { saltBytes in
                    sec.withUnsafeMutableBytes { secretBytes in
                        ad.withUnsafeMutableBytes { adBytes in
                            var context = argon2_context()
                            context.out = outBytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
                            context.outlen = UInt32(length)
                            context.pwd = pwdBytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
                            context.pwdlen = UInt32(password.count)
                            context.salt = saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
                            context.saltlen = UInt32(salt.count)
                            context.secret = secretBytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
                            context.secretlen = UInt32(secret.count)
                            context.ad = adBytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
                            context.adlen = UInt32(associated.count)
                            context.t_cost = iterations
                            context.m_cost = memoryKiB
                            context.lanes = parallelism
                            context.threads = 1
                            context.version = UInt32(ARGON2_VERSION_13.rawValue)
                            context.flags = 0 // ARGON2_DEFAULT_FLAGS
                            return argon2_ctx(&context, Argon2_id)
                        }
                    }
                }
            }
        }
        guard status == ARGON2_OK.rawValue else { throw Failure.badKDF }
        return out
    }

    /// A key that decrypts `EncString`s: 32 bytes to decrypt, and (for type 2) 32 to check the MAC.
    public struct SymmetricKey: Sendable {
        let encryption: Data
        let mac: Data?

        /// The master key stretched with HKDF-SHA256 (expand only): "enc" and "mac".
        public static func stretched(masterKey: Data) -> SymmetricKey {
            let prk = CryptoKit.SymmetricKey(data: masterKey)
            let enc = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data("enc".utf8), outputByteCount: 32)
            let mac = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data("mac".utf8), outputByteCount: 32)
            return SymmetricKey(
                encryption: enc.withUnsafeBytes { Data($0) },
                mac: mac.withUnsafeBytes { Data($0) })
        }

        /// The master key as is, for account keys wrapped the old way (`0.` strings).
        public static func legacy(masterKey: Data) -> SymmetricKey {
            SymmetricKey(encryption: masterKey, mac: nil)
        }

        /// A 64-byte key: encryption then MAC.
        public init(bytes: Data) throws {
            guard bytes.count == 64 else { throw Failure.malformed }
            encryption = bytes.prefix(32)
            mac = bytes.suffix(32)
        }

        init(encryption: Data, mac: Data?) {
            self.encryption = encryption
            self.mac = mac
        }

        /// Decrypt `type.iv|data|mac` (type 2: AES-256-CBC with HMAC-SHA256, checked first) or
        /// `0.iv|data` (no MAC, only with a key that has none).
        public func decrypt(_ encString: String) throws -> Data {
            guard let dot = encString.firstIndex(of: ".") else { throw Failure.malformed }
            let kind = encString[..<dot]
            let parts = try encString[encString.index(after: dot)...].split(separator: "|", omittingEmptySubsequences: false)
                .map { part -> Data in
                    guard let data = Data(base64Encoded: String(part)) else { throw Failure.malformed }
                    return data
                }
            let iv: Data
            let ciphertext: Data
            switch (kind, parts.count, mac) {
            case ("2", 3, let macKey?):
                iv = parts[0]
                ciphertext = parts[1]
                // Compared in constant time, so timing reveals nothing about the right tag.
                guard HMAC<SHA256>.isValidAuthenticationCode(
                    parts[2], authenticating: iv + ciphertext, using: CryptoKit.SymmetricKey(data: macKey))
                else { throw Failure.tampered }
            case ("0", 2, nil):
                iv = parts[0]
                ciphertext = parts[1]
            default:
                throw Failure.malformed
            }
            guard iv.count == 16 else { throw Failure.malformed }
            return try aesDecrypt(ciphertext, key: encryption, iv: iv)
        }

        public func decryptText(_ encString: String) throws -> String {
            guard let text = String(data: try decrypt(encString), encoding: .utf8) else { throw Failure.decrypt }
            return text
        }
    }

    static func aesDecrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let capacity = out.count
        let status = out.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { dataBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                dataBytes.baseAddress, data.count, outBytes.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.decrypt }
        return out.prefix(written)
    }
}
