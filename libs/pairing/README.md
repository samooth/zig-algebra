# zig-pairing

Bilinear pairings for pairing-friendly elliptic curves.

## Status

| Curve | Pairing | Tests | Notes |
|-------|---------|-------|-------|
| BLS12-381 | ✅ optimal ate (verified bilinear) | 14 | M-twist, ξ = 1+u |
| BN254 | — | 0 | D-type twist, ξ = 9+u; needs separate tower setup |

## Architecture

- `src/tower.zig` — generic sextic tower Fp₁₂ = Fp₆[w]/(w²−v), Fp₆ = Fp₂[v]/(v³−ξ)
- `src/bls12_381.zig` — BLS12-381 optimal ate pairing with sparse Miller loop
- `src/root.zig` — generic Fp₂/Fp₆/Fp₁₂ types + re-exports

## BLS12-381 Pairing

```
e(P ∈ G₁, Q ∈ G₂) → GT ⊂ Fp₁₂
```

Miller loop over seed bits x = −0xd201000000010000 (verified x ≡ p¹ mod r);
affine lines evaluated at P via a slot-(0,2,3) sparse Fp₁₂ multiplication.
Final exponentiation: full square-and-multiply over N = (p¹²−1)/r.

### Verified properties
- Non-degenerate: e(G₁, G₂) ≠ 1
- r-torsion: e(G₁, G₂)^r = 1
- Bilinear: e(aP, bQ) = e(P,Q)^{ab}

## Running Tests

```bash
cd libs/pairing && zig build test
```

Debug mode: ~30 s (dominated by final exponentiation SA&M).
ReleaseFast: expected <100 ms.

## License

MIT OR Apache-2.0
