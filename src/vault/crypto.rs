//! The Bitwarden client crypto Vaultwarden expects: the master key from the master password
//! (PBKDF2-SHA256 or Argon2id), the login hash, HKDF stretching, and decrypting "EncStrings"
//! (AES-256-CBC with an HMAC-SHA256 that is checked before anything is decrypted). Every secret
//! is zeroized when dropped.

use aes::cipher::{BlockDecryptMut as _, KeyIvInit as _, block_padding::Pkcs7};
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use hmac::{Hmac, Mac as _};
use sha2::{Digest as _, Sha256};
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

type HmacSha256 = Hmac<Sha256>;
type Aes256CbcDec = cbc::Decryptor<aes::Aes256>;

#[derive(Debug, PartialEq, Eq)]
pub enum CryptoError {
    /// The KDF settings the server sent cannot be used.
    BadKdf,
    /// Not an EncString this client understands.
    Malformed,
    /// The MAC did not match: wrong key, or the data was changed.
    Tampered,
    /// The padding was wrong after decrypting.
    Decrypt,
}

impl std::fmt::Display for CryptoError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::BadKdf => "unsupported key derivation settings",
            Self::Malformed => "unreadable encrypted data",
            Self::Tampered => "wrong master password, or the data was changed",
            Self::Decrypt => "could not decrypt",
        })
    }
}

/// How the master key is derived from the master password (from the server's prelogin).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kdf {
    Pbkdf2 {
        iterations: u32,
    },
    Argon2id {
        iterations: u32,
        memory_mib: u32,
        parallelism: u32,
    },
}

/// The master key: derived from the master password and the account's email.
pub fn master_key(
    password: &str,
    email: &str,
    kdf: Kdf,
) -> Result<Zeroizing<[u8; 32]>, CryptoError> {
    let email = email.trim().to_lowercase();
    let mut key = Zeroizing::new([0u8; 32]);
    match kdf {
        Kdf::Pbkdf2 { iterations } => {
            if iterations == 0 {
                return Err(CryptoError::BadKdf);
            }
            pbkdf2::pbkdf2_hmac::<Sha256>(
                password.as_bytes(),
                email.as_bytes(),
                iterations,
                key.as_mut(),
            );
        }
        Kdf::Argon2id {
            iterations,
            memory_mib,
            parallelism,
        } => {
            // Bitwarden salts Argon2 with the SHA-256 of the email, and sends memory in MiB.
            let salt = Sha256::digest(email.as_bytes());
            let params = argon2::Params::new(
                memory_mib.saturating_mul(1024),
                iterations,
                parallelism,
                Some(32),
            )
            .map_err(|_| CryptoError::BadKdf)?;
            argon2::Argon2::new(argon2::Algorithm::Argon2id, argon2::Version::V0x13, params)
                .hash_password_into(password.as_bytes(), &salt, key.as_mut())
                .map_err(|_| CryptoError::BadKdf)?;
        }
    }
    Ok(key)
}

/// What the client sends to log in: one more PBKDF2 round of the master key, salted with the
/// password. The master key itself never leaves the machine.
pub fn master_password_hash(master_key: &[u8; 32], password: &str) -> String {
    let mut hash = Zeroizing::new([0u8; 32]);
    pbkdf2::pbkdf2_hmac::<Sha256>(master_key, password.as_bytes(), 1, hash.as_mut());
    BASE64.encode(hash.as_ref())
}

/// An encryption key with its MAC key (old "type 0" keys have none).
#[derive(Zeroize, ZeroizeOnDrop)]
pub struct SymmetricKey {
    enc: [u8; 32],
    mac: Option<[u8; 32]>,
}

impl SymmetricKey {
    /// The master key stretched with HKDF into encryption and MAC keys.
    pub fn stretched(master_key: &[u8; 32]) -> Self {
        let hkdf =
            hkdf::Hkdf::<Sha256>::from_prk(master_key).expect("a 32-byte PRK is long enough");
        let (mut enc, mut mac) = ([0u8; 32], [0u8; 32]);
        hkdf.expand(b"enc", &mut enc)
            .expect("32 bytes is a valid HKDF length");
        hkdf.expand(b"mac", &mut mac)
            .expect("32 bytes is a valid HKDF length");
        Self {
            enc,
            mac: Some(mac),
        }
    }

    /// The master key as is, for accounts whose user key predates stretching.
    pub fn legacy(master_key: &[u8; 32]) -> Self {
        Self {
            enc: *master_key,
            mac: None,
        }
    }

    /// A 64-byte key (32 encryption + 32 MAC), such as the decrypted user key.
    pub fn from_bytes(bytes: &[u8]) -> Result<Self, CryptoError> {
        if bytes.len() != 64 {
            return Err(CryptoError::Malformed);
        }
        let (mut enc, mut mac) = ([0u8; 32], [0u8; 32]);
        enc.copy_from_slice(&bytes[..32]);
        mac.copy_from_slice(&bytes[32..]);
        Ok(Self {
            enc,
            mac: Some(mac),
        })
    }

    /// Decrypt an EncString: `2.<iv>|<data>|<mac>` (or the old MAC-less `0.<iv>|<data>`).
    pub fn decrypt(&self, enc_string: &str) -> Result<Zeroizing<Vec<u8>>, CryptoError> {
        let (kind, rest) = enc_string.split_once('.').ok_or(CryptoError::Malformed)?;
        let parts: Vec<Vec<u8>> = rest
            .split('|')
            .map(|part| BASE64.decode(part).map_err(|_| CryptoError::Malformed))
            .collect::<Result<_, _>>()?;
        let (iv, data) = match (kind, parts.as_slice(), &self.mac) {
            ("2", [iv, data, tag], Some(mac_key)) => {
                let mut mac =
                    HmacSha256::new_from_slice(mac_key).map_err(|_| CryptoError::Malformed)?;
                mac.update(iv);
                mac.update(data);
                mac.verify_slice(tag).map_err(|_| CryptoError::Tampered)?;
                (iv, data)
            }
            ("0", [iv, data], None) => (iv, data),
            _ => return Err(CryptoError::Malformed),
        };
        let iv: [u8; 16] = iv
            .as_slice()
            .try_into()
            .map_err(|_| CryptoError::Malformed)?;
        let plain = Aes256CbcDec::new(&self.enc.into(), &iv.into())
            .decrypt_padded_vec_mut::<Pkcs7>(data)
            .map_err(|_| CryptoError::Decrypt)?;
        Ok(Zeroizing::new(plain))
    }

    /// Decrypt an EncString holding text.
    pub fn decrypt_text(&self, enc_string: &str) -> Result<Zeroizing<String>, CryptoError> {
        let bytes = self.decrypt(enc_string)?;
        String::from_utf8(bytes.to_vec())
            .map(Zeroizing::new)
            .map_err(|_| CryptoError::Decrypt)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Reference values computed independently with Python's hashlib/hmac and the openssl CLI.
    const PASSWORD: &str = "correct horse battery staple";
    const MASTER_KEY: &str = "52ce2d33e007a7c15b3e3083c551fcff97da83045fa80cc6bbbd2cbc52c6f084";
    const USER_KEY: &str = "2.ZGVmZ2hpamtsbW5vcHFycw==|3LHLE825a4QlhMUcSQPe0yUMM1sLIGKAKZDLOwK6xZCgqklxgQPFFZ3DCsPpx7LipJvkOJhWSL6BoN9go/T7KPFB+2HN2cUmEEvBkdjKpEs=|JIei8OKL+C3GLVk0xtCLJ7EzOObv5I+YB8YBmqD4jM4=";
    const MESSAGE: &str = "2.yMnKy8zNzs/Q0dLT1NXW1w==|/5LxAPiNDQuhpSSF011GkNR7jGn1cvh22qgGyNHoXwQUTKwdQza+eEnHzLGYqVB5|EJyRbCgIBwK9zC0UYfHU7W5RHA/OqfgMzz8anHUrX68=";

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|byte| format!("{byte:02x}")).collect()
    }

    #[test]
    fn derives_the_master_key_and_login_hash() {
        // The email is trimmed and lower-cased first.
        let key = master_key(
            PASSWORD,
            "  User@Example.com ",
            Kdf::Pbkdf2 { iterations: 5000 },
        )
        .unwrap();
        assert_eq!(hex(key.as_ref()), MASTER_KEY);
        assert_eq!(
            master_password_hash(&key, PASSWORD),
            "0FMeontUyfpu9Ga/DvERL9LMAXg9KB82VK6UqHdnKko="
        );
        assert_eq!(
            master_key(PASSWORD, "a", Kdf::Pbkdf2 { iterations: 0 }),
            Err(CryptoError::BadKdf)
        );
    }

    #[test]
    fn stretches_and_decrypts_the_user_key_then_items() {
        let key = master_key(
            PASSWORD,
            "user@example.com",
            Kdf::Pbkdf2 { iterations: 5000 },
        )
        .unwrap();
        let stretched = SymmetricKey::stretched(&key);
        assert_eq!(
            hex(&stretched.enc),
            "83b79d8c4f57f2e6ab04e4427c3fcc0d9bdeff981254a535a3df2bd2a4df84a7"
        );
        let user_key = stretched.decrypt(USER_KEY).unwrap();
        assert_eq!(
            user_key.as_slice(),
            (0u8..64).collect::<Vec<_>>().as_slice()
        );

        let user_key = SymmetricKey::from_bytes(&user_key).unwrap();
        assert_eq!(
            user_key.decrypt_text(MESSAGE).unwrap().as_str(),
            "-----BEGIN OPENSSH PRIVATE KEY-----\ntest\n"
        );
    }

    #[test]
    fn refuses_changed_data_and_wrong_keys() {
        let user_key = SymmetricKey::from_bytes(&(0u8..64).collect::<Vec<_>>()).unwrap();
        // Flip one byte of the ciphertext: the MAC check must fail before decrypting.
        let (head, tail) = MESSAGE.split_once('|').unwrap();
        let (data, tag) = tail.split_once('|').unwrap();
        let mut bytes = BASE64.decode(data).unwrap();
        bytes[0] ^= 1;
        let tampered = format!("{head}|{}|{tag}", BASE64.encode(bytes));
        assert_eq!(
            user_key.decrypt(&tampered).err(),
            Some(CryptoError::Tampered)
        );

        let wrong = SymmetricKey::from_bytes(&[7u8; 64]).unwrap();
        assert_eq!(wrong.decrypt(MESSAGE).err(), Some(CryptoError::Tampered));
        assert_eq!(
            user_key.decrypt("4.rsa-is-not-handled").err(),
            Some(CryptoError::Malformed)
        );
    }

    #[test]
    fn argon2_uses_the_hashed_email_and_mebibytes() {
        let kdf = Kdf::Argon2id {
            iterations: 1,
            memory_mib: 1,
            parallelism: 1,
        };
        let a = master_key(PASSWORD, "User@Example.com", kdf).unwrap();
        let b = master_key(PASSWORD, "user@example.com", kdf).unwrap();
        assert_eq!(a, b);
        assert_ne!(hex(a.as_ref()), MASTER_KEY);
        let bad = Kdf::Argon2id {
            iterations: 0,
            memory_mib: 1,
            parallelism: 1,
        };
        assert_eq!(master_key(PASSWORD, "a", bad), Err(CryptoError::BadKdf));
    }
}
