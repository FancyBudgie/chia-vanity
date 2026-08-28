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

fn filter_combined_result(index: u32, puzzle_hash: array<u32, 32>) {
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

// WebKit/Metal performs substantially better when the complete derivation
// stays in one invocation instead of round-tripping projective points and
// child keys through storage buffers between four separate compute passes.
// Other backends keep using the split kernels above to avoid long-dispatch
// watchdog and device-loss issues observed on Windows.
@compute @workgroup_size(64)
fn combined_search_kernel(@builtin(global_invocation_id) gid: vec3<u32>) {
  let first_offset = gid.x * 2u;
  if (first_offset >= params.count) {
    return;
  }
  let second_offset = first_offset + 1u;
  let second_enabled = second_offset < params.count;

  let first_index = params.start_index + first_offset * params.step;
  let first_child_offset = derive_unhardened_offset(first_index);
  var first_child = fixed_base_mul_generator(first_child_offset);
  first_child = projective_add_affine(first_child, account_affine());

  var second_index = 0u;
  var second_child_offset: array<u32, 32>;
  var second_child = projective_inf();
  if (second_enabled) {
    second_index = params.start_index + second_offset * params.step;
    second_child_offset = derive_unhardened_offset(second_index);
    second_child = fixed_base_mul_generator(second_child_offset);
    second_child = projective_add_affine(second_child, account_affine());
  }

  let child_inverses = projective_pair_inverses(
    first_child,
    second_child,
    second_enabled,
  );
  let first_child_affine = projective_to_affine_with_inverse(
    first_child,
    child_inverses.first,
    true,
  );
  let first_child_pk = compress_g1(first_child_affine);
  let first_synthetic_scalar = synthetic_scalar_from_child(
    first_child_pk,
    first_child_offset,
  );
  var first_synthetic = fixed_base_mul_generator(first_synthetic_scalar);
  first_synthetic = projective_add_affine(first_synthetic, account_affine());

  var second_synthetic = projective_inf();
  if (second_enabled) {
    let second_child_affine = projective_to_affine_with_inverse(
      second_child,
      child_inverses.second,
      true,
    );
    let second_child_pk = compress_g1(second_child_affine);
    let second_synthetic_scalar = synthetic_scalar_from_child(
      second_child_pk,
      second_child_offset,
    );
    second_synthetic = fixed_base_mul_generator(second_synthetic_scalar);
    second_synthetic = projective_add_affine(second_synthetic, account_affine());
  }

  let synthetic_inverses = projective_pair_inverses(
    first_synthetic,
    second_synthetic,
    second_enabled,
  );
  let first_synthetic_affine = projective_to_affine_with_inverse(
    first_synthetic,
    synthetic_inverses.first,
    true,
  );
  let first_synthetic_pk = compress_g1(first_synthetic_affine);
  filter_combined_result(
    first_index,
    standard_puzzle_hash_from_synthetic_pk(first_synthetic_pk),
  );

  if (second_enabled) {
    let second_synthetic_affine = projective_to_affine_with_inverse(
      second_synthetic,
      synthetic_inverses.second,
      true,
    );
    let second_synthetic_pk = compress_g1(second_synthetic_affine);
    filter_combined_result(
      second_index,
      standard_puzzle_hash_from_synthetic_pk(second_synthetic_pk),
    );
  }
}
