use blstrs::G1Affine;
use num_bigint::BigUint;

const G1_TABLE: &[u8] = include_bytes!("g1_table.bin");
const SHADER_PARTS: &[&str] = &[
    include_str!("shaders/types.wgsl"),
    include_str!("shaders/fp.wgsl"),
    include_str!("shaders/g1.wgsl"),
    include_str!("shaders/sha256.wgsl"),
    include_str!("shaders/scalar.wgsl"),
    include_str!("shaders/puzzle.wgsl"),
    include_str!("shaders/bech32.wgsl"),
    include_str!("shaders/filter.wgsl"),
];

pub(crate) fn shader_source() -> String {
    SHADER_PARTS.join("\n")
}

pub(crate) fn table_bytes() -> &'static [u8] {
    G1_TABLE
}

pub(crate) fn account_material(
    account_public_key: &[u8; 48],
    account_affine: &G1Affine,
) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(36 * size_of::<u32>());
    bytes.extend_from_slice(account_public_key);
    let uncompressed = account_affine.to_uncompressed();
    append_montgomery_limbs(&mut bytes, &uncompressed[..48]);
    append_montgomery_limbs(&mut bytes, &uncompressed[48..]);
    bytes
}

fn append_montgomery_limbs(output: &mut Vec<u8>, coordinate: &[u8]) {
    let modulus = BigUint::parse_bytes(
        b"1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab",
        16,
    )
    .expect("BLS12-381 modulus");
    let value = (BigUint::from_bytes_be(coordinate) << 384_usize) % modulus;
    let mut limbs = value.to_u32_digits();
    limbs.resize(12, 0);
    for limb in limbs {
        output.extend_from_slice(&limb.to_le_bytes());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use group::prime::PrimeCurveAffine;

    #[test]
    fn account_material_contains_compressed_key_and_coordinates() {
        let affine = G1Affine::generator();
        let compressed = affine.to_compressed();
        let bytes = account_material(&compressed, &affine);
        assert_eq!(bytes.len(), 144);
        assert_eq!(&bytes[..48], &compressed);
        assert!(bytes[48..].iter().any(|byte| *byte != 0));
    }
}
