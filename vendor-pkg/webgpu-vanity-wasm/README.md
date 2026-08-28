# WebGPU search resources

This small WASM package exports the WGSL search program, the fixed-base BLS12-381 table, and the selected account public key in the GPU's expected layout. The application owns the WebGPU device, pipelines, fixed-size buffers, dispatches, and cleanup in TypeScript.

Build with an LLVM clang that supports WebAssembly:

```sh
CC=/opt/homebrew/opt/llvm/bin/clang wasm-pack build --target web --out-dir pkg
```

The GPU performs unhardened child derivation, synthetic-key derivation, puzzle hashing, Bech32m matching, and candidate selection. Every reported candidate is independently re-derived with the canonical CPU Chia wallet SDK before it is shown.
