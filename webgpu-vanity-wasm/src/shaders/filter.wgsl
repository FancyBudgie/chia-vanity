fn puzzle_hash_prefix_matches(puzzle_hash: array<u32, 32>) -> bool {
  var accumulator = 0u;
  var bits = 0u;
  var produced = 0u;
  for (var i = 0u; i < 32u; i++) {
    accumulator = (accumulator << 8u) | puzzle_hash[i];
    bits += 8u;
    loop {
      if (bits < 5u) {
        break;
      }
      bits -= 5u;
      if (produced < params.prefix_len &&
          ((accumulator >> bits) & 0x1fu) != params.prefix[produced]) {
        return false;
      }
      produced += 1u;
      if (produced >= params.prefix_len) {
        return true;
      }
    }
  }
  return produced >= params.prefix_len;
}

fn pack_child_bytes(b0: u32, b1: u32, b2: u32, b3: u32) -> u32 {
  return b0 | (b1 << 8u) | (b2 << 16u) | (b3 << 24u);
}

fn store_child_pk(offset: u32, child_pk: array<u32, 48>) {
  let base = offset * 12u;
  for (var word = 0u; word < 12u; word++) {
    let byte = word * 4u;
    child_keys[base + word] = pack_child_bytes(
      child_pk[byte],
      child_pk[byte + 1u],
      child_pk[byte + 2u],
      child_pk[byte + 3u],
    );
  }
}

fn load_child_pk(offset: u32) -> array<u32, 48> {
  let base = offset * 12u;
  var child_pk: array<u32, 48>;
  for (var word = 0u; word < 12u; word++) {
    let packed = child_keys[base + word];
    let byte = word * 4u;
    child_pk[byte] = packed & 0xffu;
    child_pk[byte + 1u] = (packed >> 8u) & 0xffu;
    child_pk[byte + 2u] = (packed >> 16u) & 0xffu;
    child_pk[byte + 3u] = (packed >> 24u) & 0xffu;
  }
  return child_pk;
}

@compute @workgroup_size(64)
fn child_multiply_kernel(@builtin(global_invocation_id) gid: vec3<u32>) {
  let offset = gid.x;
  if (offset >= params.count) {
    return;
  }

  let index = params.start_index + offset * params.step;
  let child_offset = derive_unhardened_offset(index);
  projective_keys[offset] = fixed_base_mul_generator(child_offset);
}

@compute @workgroup_size(64)
fn child_finish_kernel(@builtin(global_invocation_id) gid: vec3<u32>) {
  let offset = gid.x;
  if (offset >= params.count) {
    return;
  }

  var child_projective = projective_keys[offset];
  child_projective = projective_add_affine(child_projective, account_affine());
  let child_affine = projective_to_affine(child_projective);
  let child_pk = compress_g1(child_affine);
  store_child_pk(offset, child_pk);
}

@compute @workgroup_size(64)
fn synthetic_multiply_kernel(@builtin(global_invocation_id) gid: vec3<u32>) {
  let offset = gid.x;
  if (offset >= params.count) {
    return;
  }

  let index = params.start_index + offset * params.step;
  let child_offset = derive_unhardened_offset(index);
  let child_pk = load_child_pk(offset);
  let synthetic_scalar = synthetic_scalar_from_child(child_pk, child_offset);
  projective_keys[offset] = fixed_base_mul_generator(synthetic_scalar);
}

@compute @workgroup_size(64)
fn search_finish_kernel(@builtin(global_invocation_id) gid: vec3<u32>) {
  let offset = gid.x;
  if (offset >= params.count) {
    return;
  }

  let index = params.start_index + offset * params.step;
  var synthetic_projective = projective_keys[offset];
  synthetic_projective = projective_add_affine(synthetic_projective, account_affine());
  let synthetic_affine = projective_to_affine(synthetic_projective);
  let synthetic_pk = compress_g1(synthetic_affine);
  let puzzle_hash = standard_puzzle_hash_from_synthetic_pk(synthetic_pk);

  if (params.suffix_len == 0u) {
    if (puzzle_hash_prefix_matches(puzzle_hash)) {
      atomicMin(&lowest_hit_index, index);
    }
    return;
  }

  let address_values = bech32_data_values(params.hrp_kind, puzzle_hash);

  if (bech32_values_match(address_values)) {
    atomicMin(&lowest_hit_index, index);
  }
}
