use base64::Engine;
use sha2::{Digest, Sha256};

/// A PKCE (S256) pair. The verifier stays in the desktop app across the browser
/// round-trip; only the challenge is sent to the server (and on to the IdP), and
/// only the verifier can redeem the one-time code returned via sure://sso/callback.
pub struct Pkce {
    pub verifier: String,
    pub challenge: String,
}

pub fn generate_pkce() -> Pkce {
    let mut bytes = [0u8; 32];
    getrandom::getrandom(&mut bytes).expect("secure RNG unavailable");
    // Hex verifier: 64 chars, all within the RFC 7636 unreserved set.
    let verifier: String = bytes.iter().map(|b| format!("{:02x}", b)).collect();
    let digest = Sha256::digest(verifier.as_bytes());
    let challenge = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(digest);
    Pkce { verifier, challenge }
}
