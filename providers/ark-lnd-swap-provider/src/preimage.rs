use rand::{rngs::OsRng, RngCore};
use sha2::{Digest, Sha256};

use crate::error::ApiError;

pub fn preimage_and_hash(
    preimage: Option<&str>,
    preimage_hash: Option<&str>,
) -> Result<(Option<String>, String), ApiError> {
    let mut preimage_bytes = preimage
        .map(|value| decode_hex32("preimage", value))
        .transpose()?;
    let supplied_hash = preimage_hash
        .map(|value| normalize_hex32("preimage_hash", value))
        .transpose()?;

    if preimage_bytes.is_none() && supplied_hash.is_none() {
        preimage_bytes = Some(random_bytes32());
    }

    let derived_hash = preimage_bytes.as_ref().map(|bytes| sha256_hex(bytes));
    if let (Some(derived), Some(supplied)) = (&derived_hash, &supplied_hash) {
        if derived != supplied {
            return Err(ApiError::bad_request(
                "preimage does not match supplied preimage_hash",
            ));
        }
    }

    let hash = supplied_hash
        .or(derived_hash)
        .expect("preimage hash is present after normalization");
    let preimage = preimage_bytes.map(hex::encode);
    Ok((preimage, hash))
}

pub fn validate_hex32(label: &str, value: &str) -> Result<(), ApiError> {
    decode_hex32(label, value).map(|_| ())
}

pub fn sha256_hex_from_hex32(label: &str, value: &str) -> Result<String, ApiError> {
    decode_hex32(label, value).map(|bytes| sha256_hex(&bytes))
}

fn normalize_hex32(label: &str, value: &str) -> Result<String, ApiError> {
    decode_hex32(label, value).map(hex::encode)
}

fn decode_hex32(label: &str, value: &str) -> Result<[u8; 32], ApiError> {
    let bytes = hex::decode(value)
        .map_err(|_| ApiError::bad_request(format!("{label} must be hex encoded")))?;
    bytes
        .try_into()
        .map_err(|_| ApiError::bad_request(format!("{label} must be 32 bytes")))
}

fn random_bytes32() -> [u8; 32] {
    let mut bytes = [0u8; 32];
    OsRng.fill_bytes(&mut bytes);
    bytes
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}
