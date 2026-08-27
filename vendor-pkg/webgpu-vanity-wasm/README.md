# WebGPU Chia vanity search

This package implements an end-to-end GPU search for Chia's unhardened public-key derivation. A 6-bit fixed-base BLS12-381 table, SHA-256 derivation, synthetic keys, puzzle hashing, Bech32m matching, and candidate selection run in one WGSL pipeline. Only the lowest matching index is read back; the application re-derives every reported match with the canonical Chia SDK.

The benchmark verifies every GPU result against `nam-blstrs`. GPU timings include affine normalization and readback. The CPU bridge timing additionally measures deserialization, compressed point encoding, and SHA-256, approximating the dependency between Chia's first and second fixed-base multiplication.

Build with an LLVM clang that supports WebAssembly:

```sh
CC=/opt/homebrew/opt/llvm/bin/clang wasm-pack build --target web --out-dir pkg
```

Serve the repository root with Vite and open `/webgpu-vanity-wasm/bench.html` in a WebGPU-capable browser.

For memory regression testing, open `/webgpu-vanity-wasm/memory-test.html`. It runs 20 consecutive full search batches by default (override with `?batches=N`) and 20 repeated create/search/free lifecycle cycles while reporting the WASM and JavaScript heap sizes.

## Verification and measured result

- Native tests check raw GPU-limb compression and a canonical known Chia address.
- Browser differential tests compare 4,096 consecutive child keys, synthetic keys, and puzzle hashes, plus exact full-address searches across representative indices and a strided range.
- The integrated application independently re-derives every GPU hit through `chia-wallet-sdk-wasm` before reporting it.
- On the development Mac's warmed in-app WebGPU device, a 262,144-candidate prefix-only batch ran at 66.9k addresses/second. The previous CPU-bridged implementation measured 29.7k addresses/second on the same browser class; discrete-GPU results vary substantially by browser and driver.
- A repeated-batch memory run processed 1,310,720 addresses. The WASM heap remained exactly 2.38 MiB for every sample, while the JavaScript heap returned from about 10.4 MiB to 6.4 MiB after collection.

The search object uses a fixed 262,144-candidate end-to-end GPU batch. Candidate keys, puzzle hashes, and address filtering remain in the shader; only one matching index is read back. Its GPU buffers are allocated once and reused for every batch. Calling `free()` or terminating its worker releases the search context.
