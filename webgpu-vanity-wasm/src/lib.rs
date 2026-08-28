use blstrs::G1Affine;
use group::prime::PrimeCurveAffine;
use wasm_bindgen::prelude::*;

mod resources;

#[wasm_bindgen(js_name = nativeSearchShader)]
pub fn native_search_shader() -> String {
    resources::shader_source()
}

#[wasm_bindgen(js_name = nativeSearchTable)]
pub fn native_search_table() -> Vec<u8> {
    resources::table_bytes().to_vec()
}

#[wasm_bindgen(js_name = nativeSearchAccountMaterial)]
pub fn native_search_account_material(account_public_key: Vec<u8>) -> Result<Vec<u8>, JsValue> {
    let compressed: [u8; 48] = account_public_key
        .try_into()
        .map_err(|_| JsValue::from_str("account public key must be 48 bytes"))?;
    let affine = Option::<G1Affine>::from(G1Affine::from_compressed(&compressed))
        .ok_or_else(|| JsValue::from_str("account public key is not a valid BLS12-381 point"))?;
    if bool::from(affine.is_identity()) {
        return Err(JsValue::from_str("account public key cannot be infinity"));
    }
    Ok(resources::account_material(&compressed, &affine))
}
