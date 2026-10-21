//! A minimal Bitwarden-protocol client for Vaultwarden: prelogin (KDF settings), log in with the
//! master password hash (plus a two-step code when the account asks for one), sync, and decrypt
//! the SSH keys in the personal vault. It runs on a background thread; nothing is cached on disk.

use std::time::Duration;

use serde_json::Value;
use zeroize::Zeroizing;

use super::crypto::{self, CryptoError, Kdf, SymmetricKey};

/// Cipher types in Bitwarden's sync data.
const SECURE_NOTE: u64 = 2;
const SSH_KEY: u64 = 5;

/// Two-step login methods this client can complete.
pub const AUTHENTICATOR: u32 = 0;
pub const EMAIL: u32 = 1;

pub struct Login {
    pub server: String,
    pub email: String,
    pub password: Zeroizing<String>,
    pub device_id: String,
    /// A two-step code and the method it is for.
    pub two_factor: Option<(u32, String)>,
}

#[derive(Debug)]
pub enum LoginError {
    /// The account needs a two-step code; the methods it offers that this client supports.
    TwoFactor(Vec<u32>),
    Rejected(String),
    Network(String),
}

impl std::fmt::Display for LoginError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::TwoFactor(_) => f.write_str("enter your two-step login code"),
            Self::Rejected(message) | Self::Network(message) => f.write_str(message),
        }
    }
}

impl From<CryptoError> for LoginError {
    fn from(err: CryptoError) -> Self {
        Self::Rejected(err.to_string())
    }
}

/// The server's base address as typed: `https://` is assumed when no scheme is given, and a path
/// is kept (for a server behind a reverse proxy at `https://example.com/vault`).
pub fn server_url(input: &str) -> Result<String, String> {
    let input = input.trim();
    let (scheme, rest) = input.split_once("://").unwrap_or(("https", input));
    if !matches!(scheme, "https" | "http") {
        return Err("The server address must start with https:// (or http://).".into());
    }
    let rest = rest.trim_end_matches('/');
    if rest.is_empty() || rest.starts_with('/') || rest.contains(char::is_whitespace) {
        return Err("Enter your Vaultwarden address, like vault.example.com.".into());
    }
    Ok(format!("{scheme}://{rest}"))
}

/// An SSH private key from the vault.
pub struct VaultKey {
    pub id: String,
    pub name: String,
    pub private_key: Zeroizing<String>,
}

/// The vault's SSH keys, and how many items were skipped (organization items need keys this
/// client does not handle yet).
pub struct Unlocked {
    pub keys: Vec<VaultKey>,
    pub skipped: usize,
}

/// Log in and decrypt the vault's SSH keys.
pub fn unlock(login: &Login) -> Result<Unlocked, LoginError> {
    let server = login.server.trim().trim_end_matches('/');
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(30))
        .build();

    let kdf = prelogin(&agent, server, &login.email)?;
    let master_key = crypto::master_key(&login.password, &login.email, kdf)?;
    let hash = Zeroizing::new(crypto::master_password_hash(&master_key, &login.password));
    let token = token(&agent, server, login, &hash)?;

    let user_key_enc = field(&token, "Key")
        .and_then(Value::as_str)
        .ok_or_else(|| LoginError::Rejected("the server did not send the account key".into()))?;
    let wrapping = if user_key_enc.starts_with("0.") {
        SymmetricKey::legacy(&master_key)
    } else {
        SymmetricKey::stretched(&master_key)
    };
    let user_key = SymmetricKey::from_bytes(&wrapping.decrypt(user_key_enc)?)?;
    let access = field(&token, "access_token")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();

    let sync: Value = agent
        .get(&format!("{server}/api/sync?excludeDomains=true"))
        .set("Authorization", &format!("Bearer {access}"))
        .call()
        .map_err(network)?
        .into_json()
        .map_err(|err| LoginError::Network(format!("unreadable sync response: {err}")))?;
    Ok(ssh_keys(&sync, &user_key))
}

/// Ask the server to email a two-step code.
pub fn send_email_code(login: &Login) -> Result<(), LoginError> {
    let server = login.server.trim().trim_end_matches('/');
    let agent = ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(30))
        .build();
    let kdf = prelogin(&agent, server, &login.email)?;
    let master_key = crypto::master_key(&login.password, &login.email, kdf)?;
    let hash = Zeroizing::new(crypto::master_password_hash(&master_key, &login.password));
    agent
        .post(&format!("{server}/api/two-factor/send-email-login"))
        .send_json(serde_json::json!({
            "email": login.email.trim(),
            "masterPasswordHash": hash.as_str(),
            "deviceIdentifier": login.device_id,
        }))
        .map_err(network)?;
    Ok(())
}

fn prelogin(agent: &ureq::Agent, server: &str, email: &str) -> Result<Kdf, LoginError> {
    let body = serde_json::json!({ "email": email.trim() });
    // Newer servers answer on the identity endpoint, older Vaultwarden on the API one.
    let response = match agent
        .post(&format!("{server}/identity/accounts/prelogin"))
        .send_json(body.clone())
    {
        Ok(response) => response,
        Err(_) => agent
            .post(&format!("{server}/api/accounts/prelogin"))
            .send_json(body)
            .map_err(network)?,
    };
    let value: Value = response
        .into_json()
        .map_err(|err| LoginError::Network(format!("unreadable prelogin: {err}")))?;
    kdf_from(&value).ok_or_else(|| {
        LoginError::Rejected(
            "the server sent key derivation settings this app does not know".into(),
        )
    })
}

fn kdf_from(value: &Value) -> Option<Kdf> {
    let number = |name: &str| {
        field(value, name)
            .and_then(Value::as_u64)
            .map(|number| number as u32)
    };
    match number("kdf")? {
        0 => Some(Kdf::Pbkdf2 {
            iterations: number("kdfIterations")?,
        }),
        1 => Some(Kdf::Argon2id {
            iterations: number("kdfIterations")?,
            memory_mib: number("kdfMemory")?,
            parallelism: number("kdfParallelism")?,
        }),
        _ => None,
    }
}

fn token(
    agent: &ureq::Agent,
    server: &str,
    login: &Login,
    hash: &str,
) -> Result<Value, LoginError> {
    let email = login.email.trim().to_owned();
    let mut form = vec![
        ("grant_type", "password".to_owned()),
        ("username", email),
        ("password", hash.to_owned()),
        ("scope", "api offline_access".to_owned()),
        ("client_id", "cli".to_owned()),
        ("deviceType", "24".to_owned()),
        ("deviceName", "gpu-terminal".to_owned()),
        ("deviceIdentifier", login.device_id.clone()),
    ];
    if let Some((provider, code)) = &login.two_factor {
        form.push(("twoFactorProvider", provider.to_string()));
        form.push(("twoFactorToken", code.trim().to_owned()));
        form.push(("twoFactorRemember", "0".to_owned()));
    }
    let form: Vec<(&str, &str)> = form
        .iter()
        .map(|(key, value)| (*key, value.as_str()))
        .collect();
    match agent
        .post(&format!("{server}/identity/connect/token"))
        .send_form(&form)
    {
        Ok(response) => response
            .into_json()
            .map_err(|err| LoginError::Network(format!("unreadable login response: {err}"))),
        Err(ureq::Error::Status(_, response)) => {
            let value: Value = response.into_json().unwrap_or(Value::Null);
            Err(login_error(&value))
        }
        Err(err) => Err(network(err)),
    }
}

/// Why a login was refused: a two-step code is needed, or the server's message.
fn login_error(value: &Value) -> LoginError {
    let providers: Vec<u32> = field(value, "TwoFactorProviders2")
        .and_then(Value::as_object)
        .map(|providers| {
            providers
                .keys()
                .filter_map(|key| key.parse().ok())
                .collect()
        })
        .or_else(|| {
            field(value, "TwoFactorProviders")
                .and_then(Value::as_array)
                .map(|providers| {
                    providers
                        .iter()
                        .filter_map(|provider| {
                            provider
                                .as_u64()
                                .map(|id| id as u32)
                                .or_else(|| provider.as_str()?.parse().ok())
                        })
                        .collect()
                })
        })
        .unwrap_or_default();
    if !providers.is_empty() {
        let supported: Vec<u32> = providers
            .into_iter()
            .filter(|provider| matches!(*provider, AUTHENTICATOR | EMAIL))
            .collect();
        if supported.is_empty() {
            return LoginError::Rejected("this account's two-step login method is not supported yet (use an authenticator app or email)".into());
        }
        return LoginError::TwoFactor(supported);
    }
    let message = field(value, "error_description")
        .or_else(|| field(value, "ErrorModel").and_then(|model| field(model, "Message")))
        .and_then(Value::as_str)
        .unwrap_or("the server refused the login");
    LoginError::Rejected(message.to_owned())
}

/// SSH keys in the sync data: SSH key items, and secure notes that hold a private key.
fn ssh_keys(sync: &Value, user_key: &SymmetricKey) -> Unlocked {
    let mut unlocked = Unlocked {
        keys: Vec::new(),
        skipped: 0,
    };
    let ciphers = field(sync, "ciphers")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    for cipher in &ciphers {
        let kind = field(cipher, "type").and_then(Value::as_u64).unwrap_or(0);
        let deleted = field(cipher, "deletedDate").is_some_and(|date| !date.is_null());
        if !matches!(kind, SECURE_NOTE | SSH_KEY) || deleted {
            continue;
        }
        if field(cipher, "organizationId").is_some_and(|org| !org.is_null()) {
            unlocked.skipped += 1;
            continue;
        }
        // Items may carry their own key, encrypted with the user key.
        let item_key = match field(cipher, "key").and_then(Value::as_str) {
            Some(key) => match user_key
                .decrypt(key)
                .and_then(|bytes| SymmetricKey::from_bytes(&bytes))
            {
                Ok(key) => Some(key),
                Err(_) => continue,
            },
            None => None,
        };
        let key = item_key.as_ref().unwrap_or(user_key);
        let decrypt = |value: Option<&Value>| {
            value
                .and_then(Value::as_str)
                .and_then(|text| key.decrypt_text(text).ok())
        };
        let private_key = if kind == SSH_KEY {
            decrypt(field(cipher, "sshKey").and_then(|ssh| field(ssh, "privateKey")))
        } else {
            decrypt(field(cipher, "notes")).filter(|notes| notes.contains("PRIVATE KEY-----"))
        };
        let (Some(private_key), Some(id)) =
            (private_key, field(cipher, "id").and_then(Value::as_str))
        else {
            continue;
        };
        let name = decrypt(field(cipher, "name"))
            .map_or_else(|| "SSH key".to_owned(), |name| name.to_string());
        unlocked.keys.push(VaultKey {
            id: id.to_owned(),
            name,
            private_key,
        });
    }
    unlocked
}

/// A field by name, in camelCase or PascalCase (servers differ).
fn field<'a>(value: &'a Value, name: &str) -> Option<&'a Value> {
    let object = value.as_object()?;
    object.get(name).or_else(|| {
        let mut chars = name.chars();
        let first = chars.next()?;
        let flipped = if first.is_lowercase() {
            first.to_uppercase().collect::<String>()
        } else {
            first.to_lowercase().collect()
        };
        object.get(&format!("{flipped}{}", chars.as_str()))
    })
}

fn network(err: ureq::Error) -> LoginError {
    match err {
        ureq::Error::Status(code, response) => {
            let message = response.into_string().unwrap_or_default();
            LoginError::Rejected(format!(
                "the server answered {code}: {}",
                message.chars().take(200).collect::<String>()
            ))
        }
        ureq::Error::Transport(transport) => {
            LoginError::Network(format!("could not reach the server: {transport}"))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_self_hosted_server_address_is_kept_as_typed() {
        let url = |input| server_url(input);
        assert_eq!(
            url("vault.example.com").unwrap(),
            "https://vault.example.com"
        );
        assert_eq!(
            url(" https://example.com/vault/ ").unwrap(),
            "https://example.com/vault"
        );
        assert_eq!(
            url("http://192.168.1.10:8080").unwrap(),
            "http://192.168.1.10:8080"
        );
        assert!(url("").is_err());
        assert!(url("https://").is_err());
        assert!(url("ftp://vault.example.com").is_err());
        assert!(url("vault example.com").is_err());
    }

    // Item fields encrypted with the user key 0..64 (see crypto tests), computed with openssl.
    const PRIVATE_KEY: &str = "2.yMnKy8zNzs/Q0dLT1NXW1w==|/5LxAPiNDQuhpSSF011GkNR7jGn1cvh22qgGyNHoXwQUTKwdQza+eEnHzLGYqVB5|EJyRbCgIBwK9zC0UYfHU7W5RHA/OqfgMzz8anHUrX68=";

    #[test]
    fn reads_kdf_settings_in_either_casing() {
        assert_eq!(
            kdf_from(&serde_json::json!({"kdf": 0, "kdfIterations": 600000})),
            Some(Kdf::Pbkdf2 { iterations: 600000 })
        );
        assert_eq!(
            kdf_from(
                &serde_json::json!({"Kdf": 1, "KdfIterations": 3, "KdfMemory": 64, "KdfParallelism": 4})
            ),
            Some(Kdf::Argon2id {
                iterations: 3,
                memory_mib: 64,
                parallelism: 4
            })
        );
        assert_eq!(
            kdf_from(&serde_json::json!({"kdf": 9, "kdfIterations": 1})),
            None
        );
    }

    #[test]
    fn tells_two_step_requests_from_wrong_passwords() {
        let two_step = serde_json::json!({"error": "invalid_grant", "TwoFactorProviders2": {"0": null, "1": {"Email": "u***@x.com"}}});
        assert!(
            matches!(login_error(&two_step), LoginError::TwoFactor(providers) if providers.contains(&AUTHENTICATOR))
        );
        let keys_only = serde_json::json!({"TwoFactorProviders": ["4"]});
        assert!(matches!(login_error(&keys_only), LoginError::Rejected(_)));
        let wrong = serde_json::json!({"error": "invalid_grant", "error_description": "Username or password is incorrect. Try again"});
        assert!(
            matches!(login_error(&wrong), LoginError::Rejected(message) if message.contains("incorrect"))
        );
    }

    #[test]
    fn finds_ssh_keys_and_skips_what_it_cannot_read() {
        let user_key = SymmetricKey::from_bytes(&(0u8..64).collect::<Vec<_>>()).unwrap();
        let sync = serde_json::json!({ "ciphers": [
            {"id": "a", "type": 5, "name": PRIVATE_KEY, "sshKey": {"privateKey": PRIVATE_KEY}},
            {"id": "b", "type": 2, "name": PRIVATE_KEY, "notes": PRIVATE_KEY},
            {"id": "c", "type": 1, "name": PRIVATE_KEY},
            {"id": "d", "type": 5, "name": PRIVATE_KEY, "sshKey": {"privateKey": PRIVATE_KEY}, "deletedDate": "2026-01-01"},
            {"id": "e", "type": 5, "organizationId": "org", "sshKey": {"privateKey": PRIVATE_KEY}},
        ]});
        let unlocked = ssh_keys(&sync, &user_key);
        let ids: Vec<&str> = unlocked.keys.iter().map(|key| key.id.as_str()).collect();
        assert_eq!(ids, ["a", "b"]);
        assert_eq!(unlocked.skipped, 1);
        assert!(
            unlocked.keys[0]
                .private_key
                .starts_with("-----BEGIN OPENSSH PRIVATE KEY-----")
        );
    }
}
