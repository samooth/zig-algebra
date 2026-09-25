# Security Policy

## Advisory ZA-2026-001 — zig-fri `verify()` is not a low-degree test

**Affected:** the `zig-fri` implementation released in zig-algebra 0.3.0 and
earlier, including the historical snapshot under
`zig-pkg/zig_algebra-0.3.0-*`.

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

The current tree was verified with:

```text
zig build test --summary all
zig build test --summary all -Doptimize=ReleaseFast
zig build stark
```

Both test modes passed 297/297 tests, and the STARK demo accepted the honest
proof while rejecting a tampered proof. The FRI tests also pass through the
standalone `libs/fri` build.

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
