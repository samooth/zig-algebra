# zig-field Improvements Roadmap

> Auto-generated from code review on 2026-08-20.

## Quick Wins (High Impact, Low Effort)

- [x] `batchInv` — Batch inversion via Montgomery's trick (O(n) muls + 1 inv)
- [x] `powFast` — Non-constant-time exponentiation (~2x faster for public exponents)
- [x] `BigField.toBytes()` — Serialize Montgomery form back to bytes
- [x] `sqr()` — Dedicated squaring (CIOS optimized, ~30% faster than mul(x,x))
- [x] `eqCT()` / `isZeroCT()` — Constant-time equality for secret data
- [x] `fromIntStrict()` — Rejects values >= MODULUS (catches bugs early)
- [x] `toInt()` — Convert field element back to integer
- [x] `mulBy2/3/4/5()` — Multiply by small constants (common in constraint polys)
- [x] M61 predefined field (2^61 - 1, largest Mersenne in u64)
- [x] `zeroize()` — Secure memory wipe for secret values
- [x] `fromBytesBE()` / `toBytesBE()` — Big-endian serialization
- [x] Edge-case tests (inv(0), pow(x,0), sqrt(0), etc.)
- [x] CI/CD GitHub Actions (Linux/macOS/Windows, zig 0.13 + master)
- [x] `build.zig` docs step (`zig build docs`)

## Medium Term (1-2 days)

- [x] NTT/INTT native module (`src/ntt.zig`) with Vec8 SIMD butterflies
- [x] `multiExp()` — Multi-scalar exponentiation (Pippenger-style)
- [x] `frobenius()` for quadratic extensions (pairings)
- [x] BN254_Fp6 / Fp12 tower extensions
- [x] BLS12_381_Fp2 / Fp6 / Fp12 tower extensions
- [x] StarkNet field (2^251 + 17*2^192 + 1)
- [x] Pasta fields (Pallas, Vesta) for recursive SNARKs
- [x] `randomBounded()` — Unbiased random with bounded rejection
- [x] `isNegative()` / `lexicographicCmp()` for canonical forms
- [x] `batchAdd()` / `batchSub()` / `batchMul()` — Vectorized batch operations

## Completed Long-Term
- [x] `MerkleTree(F)` — Merkle tree over finite fields (building block for FRI, KZG)

## Long Term (1+ week)

- [ ] Full pairing implementation (Miller loop + final exponentiation)
- [ ] KZG commitment scheme
- [x] IPA (Inner Product Argument) commitment
- [ ] FRI (Fast Reed-Solomon IOP) prover/verifier
- [ ] `zig-afl` fuzzing integration
- [ ] Formal verification of Montgomery CIOS correctness
- [ ] GPU backend (CUDA/OpenCL) for batch operations
- [ ] WASM target optimization
