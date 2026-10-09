# Landscape scan: `zig-algebra` vs. the 2026 external results

Second pass, after reading the papers rather than their abstracts. Written
2026-10-09.

The external corpus is at `/ai/repos/2026/math`: 719 manuscripts, 372 families,
produced by an unreleased internal model (~3 h of ChatGPT Pro thinking compute per
result, ~4,000 problems posed). **300 of 719 top-line results are formalized in
Lean (42%)** — and the catalogue that says so reports
`status.scope: "Partial progress."`, `review.status: "unchecked"`, and
`automation.methods: [agent]`. Three manuscripts were withdrawn on 2026-10-07 over
a sign error. Every judgement below is conditional on that provenance.

---

## Part 1 — the library

### Shape

17 libraries under `libs/`, Zig 0.16.0, workspace **0.6.0** (`build.zig.zon:3`),
594 tests, no independent cryptographic audit. Five mathematical layers:

| Layer | Content |
|---|---|
| **Prime fields** | `Field(modulus)` dispatches at comptime: `SmallField` (<2^64, Mersenne split reduction) or `BigField` (≥2^64, CIOS Montgomery). Predefined: M31, M61, BabyBear, KoalaBear, Goldilocks, StarkNet_Fp, Pallas_Fp, Vesta_Fp, BN254_Fp, BLS12_381_Fp. Towers `CM31`, `QM31`, `BN254_Fp2`. M31-only 8-lane `Vec8` NTT. Legendre, Tonelli–Shanks, primitive roots of unity **without factoring p−1** |
| **Binary fields** | Wiedemann/Binius tower to 2^128 (`libs/binary-field/src/tower.zig`, cites `eprint 2023/1784`), GF(2^128)-GCM, CLMUL — **x86 PCLMULQDQ only, no ARM PMULL** |
| **Curves** | BN254, BLS12-381, Pallas/Vesta 2-cycle, plus stdlib (Ed25519, Ristretto, secp256k1, P-256/384). Jacobian 4-bit windowed ladder, Pippenger MSM, hash-to-curve **SvdW** RFC 9380 §6.6.1 |
| **Pairings** | BLS12-381 optimal ate (M-twist, py_ecc/EIP-197 KAT). BN254: tower sparse+split (`bn254_tower`, degree 12 over Fp via 2→6→12), `bn254_direct` (degree 12 over Fp2 but **degree 24 over Fp** — the header says so above the code), and a legacy `bn254.zig` that is **not bilinear** (ZA-2026-007) |
| **Proof stack** | FRI v2 (2-adic domains + torus over M31/M61 via Cayley parametrisation), sum-check, MLE + packed MLE, MlePcs, KZG over BN254 (synthetic setup), IPA (`verify` is a stub) |

Hashes: Blake3 (fixed in 0.5.2; it was not Blake3 before), Blake2, Keccak/SHA3,
Poseidon (StarkNet/CryptoExperts + IAIK Grain parameter sets), MiMC.

### Known gaps, ranked by whether anything external could close them

| Site | Gap | Can the corpus close it? |
|---|---|---|
| `libs/poly` | multiplication naive O(n²), no Karatsuba (`README.md:208`) | Partially — see fam 107 |
| `libs/ntt` | radix-2 only, no radix-4/8, no Bluestein (`README.md:156`) | No — the DFT results are over ℂ with a finite-field disclaimer |
| `libs/field/src/ipa.zig:237` | `verify` is `error.Unsupported`; challenges not Fiat–Shamir | No |
| `libs/transcript` | house design, no published spec (`docs/requirements.md:91`) | No |
| `libs/kzg` | `Setup.generate` publishes τ | No |
| `libs/pairing` | no external KAT for BN254 in any of three implementations | No |
| `libs/binary-field/src/clmul.zig` | x86 only | No |

Absent entirely, zero hits: lookup/permutation arguments, memory checking, GKR,
Nova/HyperNova, Jolt/Lasso, Circle STARK, zkVM, Poseidon2/Rescue/Anemoi, eta
pairing, isogenies, Elligator, VDF/class groups, real SSWU. No graphs, no lattices,
no curves over ℚ, no L-functions — which structurally excludes most of the corpus.

---

## Part 2 — the results, verified

### fam 279 — "Exact quantum factoring over a fixed finite gate set" — **corrected**

My first pass repeated the user's one-line gloss, "rompe la criptografía". Having
read the paper, **that is not what it says, and the correction matters more than
the original claim.**

Theorem 1.1, verbatim:

> "There is a polynomial-time uniform family of polynomial-size quantum circuits
> that outputs the complete prime factorization of every input integer N ≥ 2 with
> probability one. The number of gates and qubits is bounded by a fixed polynomial
> in the bit length of N. One fixed finite gate set suffices: NOT, CNOT, Toffoli,
> Hadamard, diag(1,i), their inverses, and their singly controlled versions."

What it actually is: **Shor's algorithm with the QFT replaced.** The primitive is
still order-finding plus one amplitude-amplification step; the reduction to gcd
"follows the Miller–Shor reduction". The new ingredient is a four-phase step state
$|\chi\rangle$ used in place of Fourier eigenstates. No new primitive.

The decisive caveats, all verified in the text:

- **Perfect-gate model.** "Fault", "noise", "decoherence", "error correction",
  "logical qubit" and "threshold" appear **nowhere** in the 24 pages. It says
  nothing about factoring on real hardware.
- The paper's own words: *"Its large polynomial parameters are not intended as
  practical resource improvements."*
- The strings "RSA", "elliptic curve", "ECDLP" and "Diffie" **do not occur**. Its
  only cryptographic sentence is a disclaimer: *"It makes no claim of a classical
  deterministic or randomized polynomial-time factoring algorithm."*
- **Not in the Lean catalogue.**

So: a complexity-theoretic result about *exact* computation, replacing Shor's
bounded error with probability one. Shor already gave polynomial-time factoring.
This does not move the threat model for this library, and citing it as "breaks
cryptography" would be exactly the error `AGENTS.md` §0 warns about — repeating a
characterisation without checking what the instrument actually measured.

### fam 107 — matrix multiplication, two papers, both formalized

**A. Staggered extraction (2026-09-24).** Theorem 1.1 verbatim:

> "Over every fixed field F, the arithmetic exponent of square matrix
> multiplication satisfies ω_F < 2.371054886006746 < 2.371054887."

Formalized in Lean as
`OAI.MatrixAllFields.MatrixMultiplication.AllFieldBound.omega_lt_source_constant`,
and the statement is literally `∀ (F : Type u) [Field F], Arithmetic.omega F < …`
— **no hypothesis on F**. I re-derived the arithmetic from the certified
constants: 3(8·ln7 − 5.6129839560592367565)/12.5947703215946763625 =
2.3710548860067456849, matching the claimed bound.

How it achieves characteristic-independence is the interesting part. It never
invokes border rank, degeneration, extension fields or interpolation at all:
Lemma 2.2 is an integer coefficient-count identity ("no interpolation or field
division is needed"), and Lemma 4.2 repairs holes by variable identification
("There is no division or characteristic restriction"). The classical
small-field degeneracy of Coppersmith–Winograd is sidestepped by never entering
the framework where it bites. The paper does not *discuss* that literature, which
is a rhetorical gap rather than a mathematical one.

Honest limits, from the paper: the gain over the previous 2.371177 is 1.22·10⁻⁴;
there is no optimality claim ("The proof requires a single feasible choice of
parameters"); and the limits are non-uniform in the lot count — "we first take the
divisible strand count N to infinity…; the number of lots tends to infinity last",
so β < 1 is verified only for the fixed certified data. The tensor power is the
8th, not the 32nd. The verification script checks the finite certificates, "not
the tensor constructions or limiting arguments".

**B. Nine Fourths (2026-10-02).** Theorem 1.1 verbatim: *"For every ε > 0, two
n × n complex matrices can be multiplied using O_ε(n^{9/4+ε}) arithmetic
operations. In particular, ω ≤ 9/4."* Over ℂ only. Formalized as
`OAI.MatrixMultiplication.complex_omega_le_nine_quarters`.

This is the real headline — 2.371 → 2.25 over ℂ, the largest drop in decades. **But
it does not transfer to positive characteristic**, for two independent structural
reasons I verified in the text:

1. **Roots of unity.** The separation gadget needs a primitive L-th root with
   L = 5M, where M = Π N!/(Nq_i)! = exp(N·H(q)) is exponential in N, and the
   no-wraparound condition 3(M−1) < L. Over F_q this forces q ≡ 1 mod L — an
   extension field of astronomical degree. To run it over GF(2⁸) you would need
   GF(2^{8d}) with 5M | 2^{8d}−1.
2. **Interpolation.** Bini's argument interpolates at jL+1 distinct nonzero
   values of ε. A finite field has |F| elements, so jL+1 > |F| for large j.

So the 2.25-vs-2.371 gap is precisely the price of characteristic-0 machinery.
For this library the actionable statement is: **sub-cubic is available in
characteristic 2^128 with no extension field**, which is the warrant `libs/poly`'s
missing Karatsuba did not have last year. The action is still Karatsuba with a KAT
against the naive product — not ω̄, whose constants are astronomically beyond any
size this library handles.

### fam 130 — DFT power saving — **not applicable, and it says so**

Theorem 1.1: exact DFT over ℂ in O(n(log n)^θ(log log n)^{4−θ}) with
θ = 0.999999999999789356…, so the saving is 1−θ ≈ 2.1·10⁻¹³ in the logarithm.
Corollary 1.2 gives o(n log n). Formalized — but via a *different, stronger*
network (32 binary coordinates, 4060 triples, 2⁵⁰ envelope versus the paper's
h=100/161700/2⁷¹); the paper's own Appendix A certificate-search route is
explicitly outside the formalization.

Decisive quotation: *"It is **not** a result about integer bit complexity,
bounded-coefficient circuits, numerical stability, **finite fields**, or formal
power-series algorithms."* `libs/ntt` is an NTT over finite fields with roots of
unity. Zero transfer.

### fam 116 — noncommutative polynomial identity testing, four papers

This is the family I under-weighted on the first pass, and it is the one whose
subject matter is closest to `libs/binary-field`. Four papers, 2026-09-24 to
2026-10-04:

| Paper | Statement | Formalized |
|---|---|---|
| **One Rational Matrix Hitting Point for Noncommutative Formulas** | One tuple of rational matrices detects every nonzero polynomial computed by a noncommutative division-free formula of prescribed size; dimension O(ns²); **over every field of characteristic zero** | no |
| **Polynomial Hitting Lists for Noncommutative Rational Formulas** | A polynomial-size *list* of rational matrix tuples for noncommutative *rational* formulas over ℚ of bounded tree size; every nonzero admissible formula has a defined invertible value at some tuple, with no separate bounds on inverse nesting or rational constant heights | **yes** — `OAI.RationalHitting.main`, `lean/OAI/Computability/RationalHitting/Main.lean`, 4 files |
| **Uniform Matrix Hitting Points in Every Positive Characteristic** | **One** matrix substitution detects every nonzero size-s division-free noncommutative formula over every field of a given positive characteristic; O(n³s⁶) matrices over F_p in deterministic polynomial bit time; the same tuple works with arbitrary extension-field coefficients, **including characteristic two** | no |

The progression is the point. 24 September gives a single hitting point over
characteristic zero. 4 October gives a single substitution over *every* positive
characteristic, and states explicitly that it survives arbitrary extension-field
coefficients in characteristic two — which is the exact setting of
`libs/binary-field`'s Binius tower, where elements live in a u128 across a chain
of quadratic extensions and subfield embedding is zero-cost.

Why it matters here: **`libs/poly` has no polynomial identity testing at all.**
Not as a gap in its README — as an absent capability. PIT is the operation that
decides whether a computed polynomial is zero, and it is the primitive behind
division, gcd, and factorization. The library has none of those either, and this
family supplies the constructive machinery, with one link formalized and the
characteristic-two link stated but unverified.

The honest assessment is the same shape as fam 107: the formalized result is over
ℚ, the result that would actually matter for this library is the
characteristic-positive one, and that one is not formalized. The O(n³s⁶) dimension
is high but polynomial, and the construction is deterministic.

### Deterministic polynomial factorization over prime fields — **a long chain, one link verified**

This is the most structurally interesting result in the corpus for a library with
`libs/poly`, so I traced the dependency chain end to end.

**Theorem 1.1 (factorization).** Given prime p in binary and dense f ∈ F_p[x] of
degree n, outputs all distinct monic irreducible factors with multiplicities in
O(((n+1)⌈log₂p⌉)^12 / 2^10) bit operations, absolute constant. "The algorithm
uses no randomness, integer-factorization oracle, primitive-root oracle, or GRH
assumption." The exponent 12 is explicitly "deliberately generous".

**Theorem 11.1 (= Theorem 1.2 of the companion, "Primitive roots for every
admissible integer base").** For every cyclotomic field F containing μ₁₂ and every
finite-order Hecke character η of F, L_F(s,η) has no zeros in Re s > 1 − 10⁻⁶, with
no conductor or imaginary-part restriction.

The chain, with formalization status:

```
Quasi-Riemann, Re(s) > 7/8            [FORMALIZED — lean/formalization.yaml:777]
        │  coefficient reflection + additive probe over Q(√−3)
        ▼
Hecke zero-free, Re(s) > 1 − 10⁻⁶     [NOT formalized]
        │  supplies the auxiliary-prime bound
        ▼
Primitive roots, every admissible a   [NOT formalized]
        │  Section 11, "the only place the companion's analytic theorem enters"
        ▼
Deterministic factorization of F_p[x] [NOT formalized]
```

Three findings that change the assessment:

1. **One of four links is verified.** The Quasi-Riemann half-plane is in Lean. The
   Hecke zero-free theorem that the algorithm actually consumes is not, and it is
   proved via Patterson's cubic theta coefficients under sextic Kummer twists over
   Q(√−3) — deep automorphic machinery of exactly the kind that historically
   attracts later corrections.
2. **The improvement over GRH is the whole point, and GRH was already enough.**
   Theorem 1.2 of the companion is an algorithm *given* the auxiliary primes; it
   becomes polynomial-time only when they are bounded by a fixed power of B, and
   "We prove this consequence from the cited zero-free theorem in Section 11. The
   reduction in Theorem 1.2 does not use that theorem." The paper also notes that
   Rónyai already had polynomial bounds under GRH. So the corpus removes GRH from
   an already-polynomial algorithm.
3. **The threshold is astronomical.** Theorem 1.2 requires p > B^200000 for
   n ≥ 2, with B = 20 + (n+1)(L+1). Combined with the exponent-12 bound, this is a
   statement about complexity theory, not about code anyone could run.

Verdict: the most interesting *mathematics* touching this library's objects, and
the least integrable. Nothing in the tree needs polynomial factorization over
F_p, and the load-bearing link is unverified.

### Computational number theory: three results, three weak links

These are the only results in the corpus whose *subject* is the arithmetic
`libs/bigint` performs. None is close to integrable, but the shape of the link is
worth recording because it is the same shape three times.

| Fam | Result | The link to the library |
|---|---|---|
| **012** joint Dickman law | log P⁺(n)/log n and log P⁺(n+1)/log n are asymptotically independent with Dickman marginals; implies P⁺(n) < P⁺(n+1) has natural density 1/2 | `libs/bigint` does trial division by the first 50 primes then deterministic Miller-Rabin. The largest-prime-factor distribution governs how far that trial division gets. Real but indirect |
| **026** large prime gaps | For every fixed C, a positive proportion of consecutive prime gaps exceed C·log p | `libs/bigint` and the KZG/curve setups search for primes. A positive-density lower bound on large gaps is the kind of statement that bounds how long such a search runs |
| **024** number of totients | Explicit asymptotic for V(x), the count of distinct values of φ up to x; V(cx)/V(x) → c | φ measures the multiplicative group's order, which is what `libs/field`'s primitive-root search depends on. Indirect |

All three are **not** formalized. All three are statements about distribution,
not about computation. The pattern: the corpus is strong on *what is true about
integers* and silent on *what can be computed with them faster*.

### Verification status, checked rather than assumed

For every result named in this document, the Lean catalogue entry was grepped by
title and the `main_results` declaration located where one exists:

| Result | In `sources:` | Has `main_results` declaration |
|---|---|---|
| Staggered extraction, every field (107-A) | yes, line 642 | **yes** — `OAI.MatrixAllFields.MatrixMultiplication.AllFieldBound.omega_lt_source_constant` |
| ω ≤ 9/4 over ℂ (107-B) | yes, line 282 | **yes** — `OAI.MatrixMultiplication.complex_omega_le_nine_quarters` |
| DFT power saving (130) | yes, line 262 | **yes** — `OAI.PowerSaving.transform_main`, `convolution_main` |
| Polynomial Hitting Lists (116) | yes, line 527 | **yes** — `OAI.RationalHitting.main`, 4 Lean files |
| Jacobsthal quadratic (021) | yes, line 157 | **yes** — `lean/OAI/NumberTheory/Jacobsthal/` |
| Lattice covering n log n (092) | yes, line 167 | yes |
| Depth-three square-root exponent (112) | yes, line 312 | yes |
| Circulant Hadamard (179) | yes, line 692 | **yes** |
| Log-concave sampling (139) | yes, line 657 | **yes** |
| Quasi-Riemann Re s > 7/8 (003) | yes, line 777 | **yes** |
| Landau–Siegel exclusion | yes, line 857 | **yes** |
| Short Egyptian fractions (025) | yes, line 612 | yes |
| k-median single-exponential (125) | yes, line 622 | yes |
| Mean-payoff games quasipolynomial (104) | yes, line 567 | yes |
| **Uniform Matrix Hitting Points, positive char.** | **no** | **no** |
| **Deterministic factorization over F_p[x]** | **no** | **no** |
| **Primitive roots, admissible base** | **no** | **no** |
| **Exact quantum factoring (279)** | **no** | **no** |
| Depth-five lower bounds (135) | no | no |
| Edit distance almost-linear (121) | no | no |
| FPRAS perfect matchings (113) | no | no |
| Polymatroid FPRAS (114) | no | no |
| Contingency tables (115) | no | no |
| Triangular lattice optimality (090) | no | no |
| QAC0 parity (274) | no | no |
| Dickman joint law (012) | no | no |
| Prime gaps (026) | no | no |
| Totients (024) | no | no |

The two columns are not redundant: 200 `main_results` entries sit across 173
sources, so a source can be listed without a formalized main result. Both columns
were checked for the rows above.

**The distribution is the finding, stated precisely.** Every result in this corpus
that touches an object this library actually computes *and* is formalized, is a
statement over ℚ or ℂ: matrix multiplication, hitting lists, Fourier transforms.
Every result that would reach the library's actual working fields — positive
characteristic, GF(2^128), characteristic two — is **unformalized**: the uniform
matrix hitting points, the deterministic factorization, the primitive-root input
underneath it. The corpus is verified exactly where it is least applicable, and
unverified exactly where it is most applicable.

### Adjacent results worth naming, with what they actually are
| Result | What it is | Relation to the library |
|---|---|---|
| **Universal Tensor Squares for Symmetric Groups** (fam 205) | For n ≠ 2,4,9, some irreducible representation of S_n has a tensor square containing every irreducible. Resolves the tensor-square conjecture affirmatively | Representation theory of symmetric groups. The library has no representations. Structurally out of scope |
| **Finite tensor savings and exact Fourier circuits** | Exact nonuniform Fourier circuits of size o(n log n) along an unbounded sequence of lengths, **refuting the Ω(n log n) lower bound** in the unrestricted complex linear-circuit model | Over ℂ, nonuniform. Conceptual kin to `libs/ntt`, no transfer |
| **fam 179 circulant Hadamard + Barker** (formalized) | Real circulant Hadamard matrices have order 1 or 4; Barker sequences exist exactly at 2,3,4,5,7,11,13 | Lives in the same space as transforms and permutations. Closes a constant table; no code |
| **fam 090 triangular lattice universal optimality** | Universal energy minimality for every completely monotone potential, Riesz 0<s<2, and jellium | The one genuine geometry↔proof-stack bridge: choosing evaluation domains and interpolation points *is* a point-configuration problem. Speculative |
| **fam 274 QAC0 parity lower bound** | Constant depth + unbounded-arity Toffoli cannot compute parity with fixed advantage | Lower bound; informs compression limits. Tangential to Poseidon/MiMC |
| **fam 021 Jacobsthal quadratic** (formalized) | h(k) ≪ k²/(log log 3k)² | Relates to φ and sieving; `libs/bigint` does trial division + deterministic Miller-Rabin. No direct use |

### Two false positives worth recording

**"Torus packets" are not the library's torus.**
`Equidistribution-of-Primitive-Sextic-Torus-Packets` and its quartic sibling are
about ideal-class packets of maximal orders in totally real sextic fields
equidistributing in the space of unimodular lattices. The torus in
`libs/fri/src/torus.zig` is the norm-1 torus of a quadratic extension of a
31/61-bit prime field, parametrised by the Cayley map. The shared word is
coincidence. This is the corpus analogue of the trap `AGENTS.md` names: a search
that answers about the wrong object returns a coherent zero.

**Elliptic curves over ℚ are not `libs/curve`.** Goldfeld's analytic density
conjecture, the mean analytic rank of quadratic twists, the Selmer 2-converse, and
modularity over imaginary quadratic fields are all about E/ℚ: ranks, twists,
Selmer groups. `libs/curve` has curves over F_p with fixed parameters, no
Mordell–Weil ranks, no twists. Zero implementable relevance.

### The negative result, and how it was searched

"The rest are structurally out of scope" is a claim, so here is the search that
supports it. Both catalogue files (`CONTENTS.md`, 638 KB; `overview.tex`, 321 KB)
were grepped for every term naming an object this library computes:

| Term | Hits | What the hits are |
|---|---|---|
| BN254, BLS12-381, Poseidon, Merkle, Binius, CLMUL, sum-check, KZG, IPA, Bulletproofs, Mersenne, Goldilocks, BabyBear | **0** | nothing |
| NTT, number-theoretic transform, power of two | **0** | nothing |
| discrete log, Weil pairing, isogeny, tower field, binary field, GF(2 | **0** | nothing |
| FRI (as a word) | **0** | the 5 substring hits were inside other words |
| root of unity | 2 | both in the fam 130 DFT description ("a supplied root of unity", ℂ) |
| pairing | 3 | a rational Hodge class against a complementary product (cohomological), and "pairing with a third input" for the triangular Hilbert transform (analysis). **No bilinear cryptographic pairing** |
| elliptic curve over | 12 | all E/ℚ — ranks, twists, Selmer, modularity |
| characteristic two | 10 | global function fields, the Kaplansky group-algebra counterexample, Benson–Etingof categories, **and one relevant hit**: "arbitrary extension-field coefficients, including in characteristic two" — the fam 116 uniform hitting points |
| finite field / prime field | 14 | the deterministic factorization and primitive-root papers, both already analysed above |

So the negative is measured, not asserted: **the corpus contains no result on
bilinear pairings, no result on elliptic curves over finite fields, no result on
transforms over finite fields, and no result on binary fields — with the single
exception of the characteristic-two clause in the fam 116 hitting-points paper.**
That exception is why fam 116 is the only family besides 107 that this scan
promotes to a live question.

One methodological note, because it is the same trap `AGENTS.md` records: a first
grep for "lookup" returned 10 hits, all of them inside `libs/**/.zig-cache/`
compiled binaries. Re-run over `--include='*.zig'` only, the result is zero. The
first grep did not fail — it measured the wrong object, which is the failure mode
that produces a coherent zero.

### The verification instrument itself has a caveat

The Lean catalogue is the corpus's own claim of rigour, and it self-reports
`status.scope: "Partial progress."`, `review.status: "unchecked"`, and
`automation.methods: [agent]`. 200 `main_results` entries across 173 sources. The
833 files under `lean/ComparatorChallenges/` are **independent re-implementations**
of each complexity model — `MatrixFields.lean` and `MatrixMultiplication.lean`
define their own `Gate` inductive and `eval` rather than importing a shared
library — so each bound is checked against its own model definition. The
permitted axioms in the matrix-multiplication file are only `propext`,
`Quot.sound`, `Classical.choice`, which is clean; but nobody has reviewed the
catalogue.

### A finding from the library's own tree, dated today

The repository moved while this scan was being written. Commit `3d606e1`
(2026-10-09) corrects a paragraph in `SECURITY.md`/`AUDIT.md` that said two of the
three BN254 implementations are bilinear and the defect is therefore one file.
The correction:

> "Both halves are true and the sentence is still misleading, because it leaves
> the reader to infer that bilinear means correct, and a bilinear map into the
> wrong group is still bilinear. After four releases with an untested pairing,
> that inference is the one a consumer will draw."

It then records that the three pairings do not live in the same field:

| Implementation | Field | Degree over Fp |
|---|---|---|
| py_ecc FQ12 | direct over Fq | 12 |
| `bn254_tower` Fp12 | tower 2→6→12 | 12 |
| `bn254_direct` | direct over Fp2, w¹² = ξ | **24** |

The embedding that would make a comparison possible is recorded in the commit
message rather than left implied: in Fp2[z]/(z¹² − ξ) the tower's v maps to z⁴
(because (z⁴)³ = z¹² = ξ = v³) and its w maps to z. The two attempts to pair
py_ecc's twelve Fq coefficients into six of `bn254_direct`'s Fp2 slots failed, and
the commit says why: *"they failed because they were pointed at the wrong file and
because pairing coefficients is not an isomorphism."*

This is the same lesson as the corpus, arriving from inside the library: a
property that holds (bilinearity) is not the property that certifies the thing
(correct target group), and only an external vector settles which group a pairing
lands in — which is what none of the three has. It is also the reason my first
pass of this document was wrong in two places: I called `bn254_direct` a "second
opinion" and wrote "direct degree-12" in the summary table. It is a sound
representation in a larger ring, and it is degree 24 over Fp. Both corrections are
now in the table above.

---

## Part 3 — what I would actually do

**Nothing structural, on the strength of this corpus alone.** Two families touch
objects this library computes: matrix multiplication (107) and noncommutative PIT
(116). A third would add a capability nobody here needs, via a chain with one
verified link out of four and an exponent of 12. A fourth I initially
mis-characterised and have now corrected. The remaining ~190 results are
structurally out of scope — no graphs, no lattices, no curves over ℚ, no
L-functions, no PDEs anywhere in the tree.

What the scan *did* establish, and it is worth writing down:

- **The library's real frontier is its own known gaps**, not the external
  literature. `libs/poly` O(n²), `libs/ntt` radix-2, the IPA stub, the transcript
  with no specification. None of those is closed by anything in this corpus.
- **fam 107-A is the one externally-verified warrant the library did not have**:
  sub-cubic matrix multiplication is available over every fixed field including
  GF(2^128), with no extension field and no interpolation. That converts
  `libs/poly`'s "no Karatsuba" from a performance choice into a gap with a cited
  justification. The work is a Karatsuba product with a KAT against the naive
  one — small, self-contained, and exactly the kind of change the test discipline
  here can validate.
- **fam 116 identifies an absent capability, not a slow one.** `libs/poly` has no
  polynomial identity testing, and PIT is the primitive under division, gcd and
  factorization. The characteristic-two statement is unverified, so this is a
  reason to *read* that paper, not to build on it.
- **The verification gap is itself the finding.** Every formalized result touching
  this library's objects is over ℚ or ℂ; every result reaching its actual working
  fields is unformalized. If anyone here wanted to depend on the corpus, that
  asymmetry is what they would have to resolve first — and it is the same shape as
  the library's own history, where the checked thing and the relied-upon thing
  were different objects.
- **fam 279 should not be cited as breaking cryptography.** Reading it was worth
  the effort precisely because it removed a claim I had accepted at second hand.

### One concrete, verified, immediately actionable finding

Not from the corpus — from the library's own tree, and it is the only thing this
scan turned up that someone could fix in a minute:

`AGENTS.md:660` states *"Root `build.zig.zon` carries the workspace version
(`0.5.1`)"*. The manifest carries **`0.6.0`** (`build.zig.zon:3`), and
`CHANGELOG.md:485` has a dated `## [v0.6.0] — 2026-09-30` section describing three
fixed defects, two of which shipped in published tags. The library manifests have
moved too: `field` 0.5.0, `binary-field` 0.5.0, `curve` 0.5.0, `pairing` 0.5.0,
`rng` 0.5.0, `fri` 0.4.0, `hash` 0.4.1, `bigint` 0.4.0, `transcript` 0.2.0.

So the working rules an agent reads first are one release behind the code they
govern. That is a small instance of the failure mode this repository documents
more sharply than any other: a document whose subject has moved, still asserting
the old state. `zig build counts-check` catches stale counts in Markdown; nothing
catches this, because the version is not a count.

Worth noting what the 0.6.0 changelog itself concludes, since it is the same
lesson this scan reached from the outside: *"`zig-rng` was wired into the build at
four places and imported by no `.zig` outside `libs/rng`. **The wiring is not the
consumer.**"*
  That is the same failure mode the library documents about its own Blake3 KAT.

---

## Caveats on this document

- Library version recorded here is **0.6.0**; `AGENTS.md` still says 0.5.1. That
  divergence is worth fixing independently of anything here.
- The external corpus is model-produced at 42% formalization with live
  retractions and an unreviewed catalogue. "Not formalized" is not "wrong"; it is
  "unverified by an instrument independent of its author" — the same distinction
  `AGENTS.md` §0 draws about a self-generated KAT.
- `zig build counts-check` requires every tracked Markdown file to be either read
  by one of its patterns or named in `NOT_CHECKED` with a reason. This file is the
  second of those, for the reason printed on every passing run.
