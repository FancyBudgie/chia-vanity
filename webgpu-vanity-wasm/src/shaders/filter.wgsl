override workgroup_size_x: u32 = 256;

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

@compute @workgroup_size(workgroup_size_x)
fn search_kernel(@builtin(global_invocation_id) gid: vec3<u32>) {
  let offset = gid.x;
  if (offset >= params.count) {
    return;
  }

  let index = params.start_index + offset * params.step;
  let child_offset = derive_unhardened_offset(index);
  var child_projective = fixed_base_mul_generator(child_offset);
  child_projective = projective_add_affine(child_projective, account_affine());
  let child_affine = projective_to_affine(child_projective);
  let child_pk = compress_g1(child_affine);
  let synthetic_pk = synthetic_pk_from_child(child_pk, child_affine);
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
