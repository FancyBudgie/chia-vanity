override use_unrolled_field_arithmetic: bool = false;

const N0: u32 = 0xfffcfffdu;

const P_LIMBS: array<u32, 12> = array<u32, 12>(
  0xffffaaabu, 0xb9feffffu, 0xb153ffffu, 0x1eabfffeu,
  0xf6b0f624u, 0x6730d2a0u, 0xf38512bfu, 0x64774b84u,
  0x434bacd7u, 0x4b1ba7b6u, 0x397fe69au, 0x1a0111eau,
);

const R_LIMBS: array<u32, 12> = array<u32, 12>(
  0x0002fffdu, 0x76090000u, 0xc40c0002u, 0xebf4000bu,
  0x53c758bau, 0x5f489857u, 0x70525745u, 0x77ce5853u,
  0xa256ec6du, 0x5c071a97u, 0xfa80e493u, 0x15f65ec3u,
);

const R2_LIMBS: array<u32, 12> = array<u32, 12>(
  0x1c341746u, 0xf4df1f34u, 0x09d104f1u, 0x0a76e6a6u,
  0x4c95b6d5u, 0x8de5476cu, 0x939d83c0u, 0x67eb88a9u,
  0xb519952du, 0x9a793e85u, 0x92cae3aau, 0x11988fe5u,
);

const P_MINUS_2: array<u32, 12> = array<u32, 12>(
  0xffffaaa9u, 0xb9feffffu, 0xb153ffffu, 0x1eabfffeu,
  0xf6b0f624u, 0x6730d2a0u, 0xf38512bfu, 0x64774b84u,
  0x434bacd7u, 0x4b1ba7b6u, 0x397fe69au, 0x1a0111eau,
);

const HALF_P_BE: array<u32, 48> = array<u32, 48>(
  0x0du, 0x00u, 0x88u, 0xf5u, 0x1cu, 0xbfu, 0xf3u, 0x4du,
  0x25u, 0x8du, 0xd3u, 0xdbu, 0x21u, 0xa5u, 0xd6u, 0x6bu,
  0xb2u, 0x3bu, 0xa5u, 0xc2u, 0x79u, 0xc2u, 0x89u, 0x5fu,
  0xb3u, 0x98u, 0x69u, 0x50u, 0x7bu, 0x58u, 0x7bu, 0x12u,
  0x0fu, 0x55u, 0xffu, 0xf5u, 0x8au, 0x9fu, 0xffu, 0xfdu,
  0xcfu, 0xf7u, 0xffu, 0xffu, 0xffu, 0xfdu, 0x55u, 0x55u,
);

fn fp_from_arr(v: array<u32, 12>) -> Fp {
  return Fp(
    vec4<u32>(v[0], v[1], v[2], v[3]),
    vec4<u32>(v[4], v[5], v[6], v[7]),
    vec4<u32>(v[8], v[9], v[10], v[11]),
  );
}

fn fp_to_arr(p: Fp) -> array<u32, 12> {
  var v: array<u32, 12>;
  v[0] = p.a.x; v[1] = p.a.y; v[2] = p.a.z; v[3] = p.a.w;
  v[4] = p.b.x; v[5] = p.b.y; v[6] = p.b.z; v[7] = p.b.w;
  v[8] = p.c.x; v[9] = p.c.y; v[10] = p.c.z; v[11] = p.c.w;
  return v;
}

fn fp_zero() -> Fp {
  return Fp(vec4<u32>(0u), vec4<u32>(0u), vec4<u32>(0u));
}

fn fp_one() -> Fp {
  return fp_from_arr(R_LIMBS);
}

fn fp_is_zero(p: Fp) -> bool {
  return ((p.a.x | p.a.y | p.a.z | p.a.w) |
          (p.b.x | p.b.y | p.b.z | p.b.w) |
          (p.c.x | p.c.y | p.c.z | p.c.w)) == 0u;
}

fn mul_wide(a: u32, b: u32) -> vec2<u32> {
  let a0 = a & 0xffffu;
  let a1 = a >> 16u;
  let b0 = b & 0xffffu;
  let b1 = b >> 16u;
  let p0 = a0 * b0;
  let p1 = a0 * b1;
  let p2 = a1 * b0;
  let p3 = a1 * b1;
  let cy = (p0 >> 16u) + (p1 & 0xffffu) + (p2 & 0xffffu);
  let lo = (p0 & 0xffffu) | ((cy & 0xffffu) << 16u);
  let hi = p3 + (p1 >> 16u) + (p2 >> 16u) + (cy >> 16u);
  return vec2<u32>(lo, hi);
}

fn addc(a: u32, b: u32, cin: u32) -> vec2<u32> {
  let s = a + b;
  var carry = u32(s < a);
  let s2 = s + cin;
  carry += u32(s2 < s);
  return vec2<u32>(s2, carry);
}

fn mac(t: u32, a: u32, b: u32, c: u32) -> vec2<u32> {
  let p = mul_wide(a, b);
  let r = addc(t, p.x, c);
  return vec2<u32>(r.x, p.y + r.y);
}

fn sub_borrow(a: u32, b: u32, bin: u32) -> vec2<u32> {
  let tmp = a - bin;
  let br1 = u32(a < bin);
  let diff = tmp - b;
  let br2 = u32(tmp < b);
  return vec2<u32>(diff, br1 | br2);
}

fn ge_p(a: array<u32, 12>) -> bool {
  for (var i = 12u; i > 0u; i--) {
    let ai = a[i - 1u];
    let pi = P_LIMBS[i - 1u];
    if (ai > pi) {
      return true;
    }
    if (ai < pi) {
      return false;
    }
  }
  return true;
}

fn fp_reduce(t: array<u32, 12>, extra: u32) -> array<u32, 12> {
  var v = t;
  var e = extra;
  for (var k = 0u; k < 4u; k++) {
    if (e == 0u && !ge_p(v)) {
      break;
    }
    var borrow = 0u;
    var r: array<u32, 12>;
    for (var i = 0u; i < 12u; i++) {
      let sb = sub_borrow(v[i], P_LIMBS[i], borrow);
      r[i] = sb.x;
      borrow = sb.y;
    }
    v = r;
    e -= borrow;
  }
  return v;
}

fn mont_mul_arr(a: array<u32, 12>, b: array<u32, 12>) -> array<u32, 12> {
  var t: array<u32, 12>;
  for (var i = 0u; i < 12u; i++) {
    t[i] = 0u;
  }
  var tN = 0u;
  for (var i = 0u; i < 12u; i++) {
    var C = 0u;
    for (var j = 0u; j < 12u; j++) {
      let r = mac(t[j], a[i], b[j], C);
      t[j] = r.x;
      C = r.y;
    }
    let s = addc(tN, C, 0u);
    tN = s.x;
    var extra = s.y;
    let m = t[0] * N0;
    C = 0u;
    for (var j = 0u; j < 12u; j++) {
      let r = mac(t[j], m, P_LIMBS[j], C);
      t[j] = r.x;
      C = r.y;
    }
    let s2 = addc(tN, C, 0u);
    tN = s2.x;
    extra += s2.y;
    for (var j = 0u; j < 11u; j++) {
      t[j] = t[j + 1u];
    }
    t[11] = tN;
    tN = extra;
  }
  return fp_reduce(t, tN);
}

struct WideFp {
  l0: u32,
  l1: u32,
  l2: u32,
  l3: u32,
  l4: u32,
  l5: u32,
  l6: u32,
  l7: u32,
  l8: u32,
  l9: u32,
  l10: u32,
  l11: u32,
  extra: u32,
}

struct FpReduction {
  value: Fp,
  borrow: u32,
}

struct FpWithExtra {
  value: Fp,
  extra: u32,
}

fn wide_fp_zero() -> WideFp {
  var value: WideFp;
  value.l0 = 0u;
  value.l1 = 0u;
  value.l2 = 0u;
  value.l3 = 0u;
  value.l4 = 0u;
  value.l5 = 0u;
  value.l6 = 0u;
  value.l7 = 0u;
  value.l8 = 0u;
  value.l9 = 0u;
  value.l10 = 0u;
  value.l11 = 0u;
  value.extra = 0u;
  return value;
}

fn wide_fp_value(value: WideFp) -> Fp {
  return Fp(
    vec4<u32>(value.l0, value.l1, value.l2, value.l3),
    vec4<u32>(value.l4, value.l5, value.l6, value.l7),
    vec4<u32>(value.l8, value.l9, value.l10, value.l11),
  );
}

fn fp_ge_modulus_unrolled(value: Fp) -> bool {
  if (value.c.w != P_LIMBS[11]) { return value.c.w > P_LIMBS[11]; }
  if (value.c.z != P_LIMBS[10]) { return value.c.z > P_LIMBS[10]; }
  if (value.c.y != P_LIMBS[9]) { return value.c.y > P_LIMBS[9]; }
  if (value.c.x != P_LIMBS[8]) { return value.c.x > P_LIMBS[8]; }
  if (value.b.w != P_LIMBS[7]) { return value.b.w > P_LIMBS[7]; }
  if (value.b.z != P_LIMBS[6]) { return value.b.z > P_LIMBS[6]; }
  if (value.b.y != P_LIMBS[5]) { return value.b.y > P_LIMBS[5]; }
  if (value.b.x != P_LIMBS[4]) { return value.b.x > P_LIMBS[4]; }
  if (value.a.w != P_LIMBS[3]) { return value.a.w > P_LIMBS[3]; }
  if (value.a.z != P_LIMBS[2]) { return value.a.z > P_LIMBS[2]; }
  if (value.a.y != P_LIMBS[1]) { return value.a.y > P_LIMBS[1]; }
  return value.a.x >= P_LIMBS[0];
}

fn fp_sub_modulus_unrolled(value: Fp) -> FpReduction {
  var result: FpReduction;
  var borrow = 0u;
  let r0 = sub_borrow(value.a.x, P_LIMBS[0], borrow);
  result.value.a.x = r0.x; borrow = r0.y;
  let r1 = sub_borrow(value.a.y, P_LIMBS[1], borrow);
  result.value.a.y = r1.x; borrow = r1.y;
  let r2 = sub_borrow(value.a.z, P_LIMBS[2], borrow);
  result.value.a.z = r2.x; borrow = r2.y;
  let r3 = sub_borrow(value.a.w, P_LIMBS[3], borrow);
  result.value.a.w = r3.x; borrow = r3.y;
  let r4 = sub_borrow(value.b.x, P_LIMBS[4], borrow);
  result.value.b.x = r4.x; borrow = r4.y;
  let r5 = sub_borrow(value.b.y, P_LIMBS[5], borrow);
  result.value.b.y = r5.x; borrow = r5.y;
  let r6 = sub_borrow(value.b.z, P_LIMBS[6], borrow);
  result.value.b.z = r6.x; borrow = r6.y;
  let r7 = sub_borrow(value.b.w, P_LIMBS[7], borrow);
  result.value.b.w = r7.x; borrow = r7.y;
  let r8 = sub_borrow(value.c.x, P_LIMBS[8], borrow);
  result.value.c.x = r8.x; borrow = r8.y;
  let r9 = sub_borrow(value.c.y, P_LIMBS[9], borrow);
  result.value.c.y = r9.x; borrow = r9.y;
  let r10 = sub_borrow(value.c.z, P_LIMBS[10], borrow);
  result.value.c.z = r10.x; borrow = r10.y;
  let r11 = sub_borrow(value.c.w, P_LIMBS[11], borrow);
  result.value.c.w = r11.x;
  result.borrow = r11.y;
  return result;
}

fn fp_reduce_once_unrolled(state_in: FpWithExtra) -> FpWithExtra {
  var state = state_in;
  if (state.extra == 0u && !fp_ge_modulus_unrolled(state.value)) {
    return state;
  }
  let reduced = fp_sub_modulus_unrolled(state.value);
  state.value = reduced.value;
  state.extra -= reduced.borrow;
  return state;
}

fn fp_reduce_unrolled(value: Fp, extra: u32) -> Fp {
  var state: FpWithExtra;
  state.value = value;
  state.extra = extra;
  state = fp_reduce_once_unrolled(state);
  state = fp_reduce_once_unrolled(state);
  state = fp_reduce_once_unrolled(state);
  state = fp_reduce_once_unrolled(state);
  return state.value;
}

fn montgomery_round_unrolled(state_in: WideFp, a_limb: u32, b: Fp) -> WideFp {
  var state = state_in;
  var carry = 0u;
  let a0 = mac(state.l0, a_limb, b.a.x, carry);
  state.l0 = a0.x; carry = a0.y;
  let a1 = mac(state.l1, a_limb, b.a.y, carry);
  state.l1 = a1.x; carry = a1.y;
  let a2 = mac(state.l2, a_limb, b.a.z, carry);
  state.l2 = a2.x; carry = a2.y;
  let a3 = mac(state.l3, a_limb, b.a.w, carry);
  state.l3 = a3.x; carry = a3.y;
  let a4 = mac(state.l4, a_limb, b.b.x, carry);
  state.l4 = a4.x; carry = a4.y;
  let a5 = mac(state.l5, a_limb, b.b.y, carry);
  state.l5 = a5.x; carry = a5.y;
  let a6 = mac(state.l6, a_limb, b.b.z, carry);
  state.l6 = a6.x; carry = a6.y;
  let a7 = mac(state.l7, a_limb, b.b.w, carry);
  state.l7 = a7.x; carry = a7.y;
  let a8 = mac(state.l8, a_limb, b.c.x, carry);
  state.l8 = a8.x; carry = a8.y;
  let a9 = mac(state.l9, a_limb, b.c.y, carry);
  state.l9 = a9.x; carry = a9.y;
  let a10 = mac(state.l10, a_limb, b.c.z, carry);
  state.l10 = a10.x; carry = a10.y;
  let a11 = mac(state.l11, a_limb, b.c.w, carry);
  state.l11 = a11.x; carry = a11.y;

  let upper_add = addc(state.extra, carry, 0u);
  let upper = upper_add.x;
  var next_extra = upper_add.y;
  let multiplier = state.l0 * N0;
  carry = 0u;
  let p0 = mac(state.l0, multiplier, P_LIMBS[0], carry);
  state.l0 = p0.x; carry = p0.y;
  let p1 = mac(state.l1, multiplier, P_LIMBS[1], carry);
  state.l1 = p1.x; carry = p1.y;
  let p2 = mac(state.l2, multiplier, P_LIMBS[2], carry);
  state.l2 = p2.x; carry = p2.y;
  let p3 = mac(state.l3, multiplier, P_LIMBS[3], carry);
  state.l3 = p3.x; carry = p3.y;
  let p4 = mac(state.l4, multiplier, P_LIMBS[4], carry);
  state.l4 = p4.x; carry = p4.y;
  let p5 = mac(state.l5, multiplier, P_LIMBS[5], carry);
  state.l5 = p5.x; carry = p5.y;
  let p6 = mac(state.l6, multiplier, P_LIMBS[6], carry);
  state.l6 = p6.x; carry = p6.y;
  let p7 = mac(state.l7, multiplier, P_LIMBS[7], carry);
  state.l7 = p7.x; carry = p7.y;
  let p8 = mac(state.l8, multiplier, P_LIMBS[8], carry);
  state.l8 = p8.x; carry = p8.y;
  let p9 = mac(state.l9, multiplier, P_LIMBS[9], carry);
  state.l9 = p9.x; carry = p9.y;
  let p10 = mac(state.l10, multiplier, P_LIMBS[10], carry);
  state.l10 = p10.x; carry = p10.y;
  let p11 = mac(state.l11, multiplier, P_LIMBS[11], carry);
  state.l11 = p11.x; carry = p11.y;

  let reduced_upper = addc(upper, carry, 0u);
  next_extra += reduced_upper.y;
  var next: WideFp;
  next.l0 = state.l1;
  next.l1 = state.l2;
  next.l2 = state.l3;
  next.l3 = state.l4;
  next.l4 = state.l5;
  next.l5 = state.l6;
  next.l6 = state.l7;
  next.l7 = state.l8;
  next.l8 = state.l9;
  next.l9 = state.l10;
  next.l10 = state.l11;
  next.l11 = reduced_upper.x;
  next.extra = next_extra;
  return next;
}

fn mont_mul_unrolled(a: Fp, b: Fp) -> Fp {
  var state = wide_fp_zero();
  state = montgomery_round_unrolled(state, a.a.x, b);
  state = montgomery_round_unrolled(state, a.a.y, b);
  state = montgomery_round_unrolled(state, a.a.z, b);
  state = montgomery_round_unrolled(state, a.a.w, b);
  state = montgomery_round_unrolled(state, a.b.x, b);
  state = montgomery_round_unrolled(state, a.b.y, b);
  state = montgomery_round_unrolled(state, a.b.z, b);
  state = montgomery_round_unrolled(state, a.b.w, b);
  state = montgomery_round_unrolled(state, a.c.x, b);
  state = montgomery_round_unrolled(state, a.c.y, b);
  state = montgomery_round_unrolled(state, a.c.z, b);
  state = montgomery_round_unrolled(state, a.c.w, b);
  return fp_reduce_unrolled(wide_fp_value(state), state.extra);
}

fn fp_mul(a: Fp, b: Fp) -> Fp {
  if (use_unrolled_field_arithmetic) {
    return mont_mul_unrolled(a, b);
  }
  return fp_from_arr(mont_mul_arr(fp_to_arr(a), fp_to_arr(b)));
}

fn fp_sqr(a: Fp) -> Fp {
  return fp_mul(a, a);
}

fn fp_add(a: Fp, b: Fp) -> Fp {
  var r: array<u32, 12>;
  var carry = 0u;
  let aa = fp_to_arr(a);
  let bb = fp_to_arr(b);
  for (var i = 0u; i < 12u; i++) {
    let s = addc(aa[i], bb[i], carry);
    r[i] = s.x;
    carry = s.y;
  }
  return fp_from_arr(fp_reduce(r, carry));
}

fn fp_dbl(a: Fp) -> Fp {
  return fp_add(a, a);
}

fn fp_sub(a: Fp, b: Fp) -> Fp {
  var r: array<u32, 12>;
  var borrow = 0u;
  let aa = fp_to_arr(a);
  let bb = fp_to_arr(b);
  for (var i = 0u; i < 12u; i++) {
    let sb = sub_borrow(aa[i], bb[i], borrow);
    r[i] = sb.x;
    borrow = sb.y;
  }
  if (borrow != 0u) {
    var carry = 0u;
    for (var i = 0u; i < 12u; i++) {
      let s = addc(r[i], P_LIMBS[i], carry);
      r[i] = s.x;
      carry = s.y;
    }
  }
  return fp_from_arr(r);
}

fn fp_to_mont(a: Fp) -> Fp {
  return fp_from_arr(mont_mul_arr(fp_to_arr(a), R2_LIMBS));
}

fn fp_from_mont(a: Fp) -> Fp {
  var one: array<u32, 12>;
  one[0] = 1u;
  for (var i = 1u; i < 12u; i++) {
    one[i] = 0u;
  }
  return fp_from_arr(mont_mul_arr(fp_to_arr(a), one));
}

fn fp_from_be48_bytes(be: array<u32, 48>) -> Fp {
  var limbs: array<u32, 12>;
  for (var i = 0u; i < 12u; i++) {
    let j = 48u - 4u * (i + 1u);
    limbs[i] = (be[j] << 24u) | (be[j + 1u] << 16u) | (be[j + 2u] << 8u) | be[j + 3u];
  }
  return fp_to_mont(fp_from_arr(limbs));
}

fn fp_to_be48_bytes(p: Fp) -> array<u32, 48> {
  let n = fp_to_arr(fp_from_mont(p));
  var be: array<u32, 48>;
  for (var i = 0u; i < 12u; i++) {
    let w = n[i];
    let j = 48u - 4u * (i + 1u);
    be[j] = (w >> 24u) & 0xffu;
    be[j + 1u] = (w >> 16u) & 0xffu;
    be[j + 2u] = (w >> 8u) & 0xffu;
    be[j + 3u] = w & 0xffu;
  }
  return be;
}

fn fp_pow(base: Fp, exp: array<u32, 12>) -> Fp {
  var start = 384u;
  for (var bit = 0u; bit < 384u; bit++) {
    let limb = 11u - bit / 32u;
    let b = 31u - (bit % 32u);
    if (((exp[limb] >> b) & 1u) != 0u) {
      start = bit;
      break;
    }
  }
  if (start >= 384u) {
    return fp_one();
  }
  var acc = base;
  var bit = start + 1u;
  loop {
    if (bit >= 384u) {
      break;
    }
    acc = fp_sqr(acc);
    let limb = 11u - bit / 32u;
    let b = 31u - (bit % 32u);
    if (((exp[limb] >> b) & 1u) != 0u) {
      acc = fp_mul(acc, base);
    }
    bit += 1u;
  }
  return acc;
}

fn fp_inverse(value: Fp) -> Fp {
  return fp_pow(value, P_MINUS_2);
}

fn fp_is_lexicographically_largest(y: Fp) -> bool {
  let yb = fp_to_be48_bytes(y);
  for (var i = 0u; i < 48u; i++) {
    if (yb[i] > HALF_P_BE[i]) {
      return true;
    }
    if (yb[i] < HALF_P_BE[i]) {
      return false;
    }
  }
  return true;
}
