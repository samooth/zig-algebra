# Security Policy

## No independent audit

**No independent cryptographic audit exists for any library in this
workspace.** Passing the test suite, matching EIP-197/py_ecc known-answer
vectors and being covered by negative tests are *not* an audit. Every use of
this code — especially `pairing`, `fri`, `kzg` and `binary-field` — requires
your own review, threat model and parameter selection.

## Scope and non-claims

- **Constant time:** not guaranteed. Field inversion (binary GCD), BigInt
  comparison, square roots, curve `scalarMul` and both BN254/BLS12-381 pairing
  implementations are data-dependent. The Montgomery `mul`/`add`/`sub` core is
  constant-time; see `DESIGN.md` for the per-operation list.
- **KZG setup:** `Setup.generate` is synthetic (caller-chosen `tau`) and is for
  tests and development only. Production needs a verified powers-of-tau
  ceremony with toxic-waste destruction.
- **IPA:** `Ipa.verify` in `zig-field` is a stub that returns
  `error.Unsupported`; only `Ipa.verifyWithCommitment` verifies. Its challenges
  are a local SHA-256 over `(L, R, round)`, **not** a `zig-transcript`
  Fiat-Shamir session, so the module is not transcript-composable and is not
  safe to use as-is in a larger protocol.
- **Benchmarks:** `zig build bench` numbers are machine-specific measurements,
  not guarantees. CI stores them as an artifact with no regression thresholds.
- **Examples and demos:** `examples/*` and per-library `main.zig` programs are
  demonstrations, not protocol implementations.
- **Entropy:** `zig-rng` seeds its process-wide ChaCha20 CSPRNG from the OS
  (`getrandom` on Linux, Windows `BCryptGenRandom`, `/dev/urandom` elsewhere,
  host-injected entropy on wasm/freestanding) and panics if secure entropy is
  unavailable. Test hooks (`setEntropy`, `setRandomForTesting`) are for
  deterministic tests only and must not be reachable in production builds.

## Advisory ZA-2026-001 — zig-fri `verify()` is not a low-degree test

**Affected:** the `zig-fri` implementation released in zig-algebra 0.3.0 and
earlier, including the immutable `v0.3.0` tag.

**Status:** the defect is fixed in the current working tree. The fix has not
been independently audited and is not, by itself, a production security
claim.

**Impact:** the affected `fri.verify()` accepted proofs of arbitrary committed
data with probability 1. A malicious prover could commit random evaluations and
produce an accepting proof. Any statement relying only on the affected FRI
verifier was therefore unproven.

## Root cause

The affected implementation had four compounding defects:

1. It treated a flat array as FRI evaluations without a Reed-Solomon subgroup
   or positional domain semantics.
2. It folded adjacent array entries without the antipodal weights required by
   FRI.
3. Its configuration had no initial degree bound or residual rate.
4. It checked the prover's own final evaluations instead of anchoring the claim
   to an independently defined low-degree residual.

The historical regression test accepted honestly folded random data 16/16
times.

## Current implementation

The current FRI implementation uses:

- the natural-order multiplicative subgroup `H_k` and antipodal pairs
  `(j, j + n/2)`;
- the positional fold
  `(f(x) + f(-x))/2 + alpha*(f(x) - f(-x))/(2*x)`;
- `log_initial_degree`, `log_final`, and `log_residual_degree` with an enforced
  relationship between the initial bound, folding rounds, and residual bound;
- Merkle commitments whose path depth must match the committed layer shape;
- residual coefficients evaluated on the final domain as the degree anchor;
- exact positional fold equality and Fiat-Shamir replay.

The regression suite covers random-data rejection, over-degree rejection,
tampered values, truncated Merkle paths, transcript desynchronization, and
non-power-of-two Merkle proofs.

## Verification performed

The current tree was re-verified with Zig 0.16.0:

```text
zig build test --summary all
zig build test --summary all -Doptimize=ReleaseFast
zig build stark
```

Both test modes passed **316/316 tests**, and the STARK demo (Fibonacci over
Goldilocks) accepted the honest proof while rejecting a tampered proof. The FRI
tests also pass through the standalone `libs/fri` build.

> History: when the fix above landed, the same commands reported 297/297
> tests — that was the suite size at the time, not a different result. The
> count has since grown with the rest of the workspace (see `README.md` for the
> per-library breakdown).

## Migration

FRI callers must provide evaluations on the canonical subgroup domain and use
the logarithmic configuration described in `libs/fri/README.md`. The old
`domain_size`/`final_length` API is not compatible with the corrected
verifier.

Do not use the historical `zig-pkg/` snapshot as evidence that the current
implementation is fixed. New deployments still require an external security
review, carefully chosen domain/degree parameters, and a real trusted setup
for the surrounding proof system.

## Reporting

Report suspected vulnerabilities privately to the maintainers. Do not disclose
security-sensitive details in a public issue or pull request.
