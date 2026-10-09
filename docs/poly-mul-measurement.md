# Measuring `Polynomial.mul`: does it need Karatsuba, and where?

Experiment date 2026-10-09. Reproduce with `zig build poly-mul-bench`
(`libs/poly/bench/mul.zig`, crossover 32). Machine: AMD Ryzen 7 5800H, Linux
x86-64, Zig 0.16.0, ReleaseFast. Treat the absolute figures as orientation; the
ratios are the point.

## The question, and where it came from

An external result supplies the theoretical warrant `zig-poly`'s O(n²) product
never had. *Staggered extraction for exact matrix multiplication over every
field* (2026-09-24, formalized in Lean as
`OAI.MatrixAllFields.MatrixMultiplication.AllFieldBound.omega_lt_source_object`
with the statement `∀ (F : Type u) [Field F], Arithmetic.omega F < …`) proves
ω_F < 2.371054886006746 over **every fixed field, including every positive
characteristic**. It does so without border rank, without degenerations, without
interpolation and without an extension field of any size — which is why the bound
reaches GF(2¹²⁸) verbatim.

A warrant is not a measurement. Sub-cubic being *available* says nothing about
whether Karatsuba is *faster at the sizes this library handles*. So: measure.

## Method, and why each choice is load-bearing

**Three baselines, not one.** Comparing Karatsuba against `libs/poly` conflates
three separate changes: the algorithm, the comptime-sized array, and the trailing
`normalize()` that scans all `max_degree+1` slots. So each row measures three
things:

| Column | What it isolates |
|---|---|
| `lib naive` | `Polynomial(F, 2d).mul` as shipped |
| `slice naive` | the same double loop over `[]const F` — no fixed array, no `normalize` |
| `karatsuba` | Karatsuba over the same slices |

`k vs slice` is the algorithmic question. `k vs lib` is what a caller would
notice.

**A correctness comparison gates every printed figure.** The first version of
this benchmark reported "Karatsuba loses" in all twenty-one cells, and was wrong.
The three accumulator buffers were sized `half+1`; when the operand count is odd
the high half has `half+1` elements and their product needs `2*half+1`
coefficients, so `z2` and `z1` overflowed and every figure measured a broken
routine. Plausible numbers, all of them. The comparison against the library's own
answer is the only thing that caught it, so it runs before the timing loop and the
row prints `NO` instead of a ratio if it fails. All rows below read `yes`.

**The minimum of seven runs, not the mean.** Taken as a single measurement,
degree 32 over Goldilocks came out at 3170 ns in one run and 6116 ns in the next
— 90% of scheduler noise on a figure whose entire job is to decide a 1.0×
threshold. This is the same finding `libs/field/bench/pow.zig` documents for
`pow`, and the same seven-repetition minimum it settled on.

**Three points on the field-cost axis.** F7 is `u64 % 7`, the field
`libs/poly`'s own tests use — reproduced in the benchmark because the library
does not export it. M31 is `SmallField` on the Mersenne fast path. Goldilocks is
`BigField` on Montgomery CIOS. Karatsuba trades field *multiplications* for field
*additions*, so its value depends on their relative cost, and one field cannot
answer for all.

## A constraint the measurement uncovered

`Polynomial(F, max_degree).mul` rejects with `error.DegreeTooLarge` when the
product's degree exceeds `max_degree`. Multiplying two degree-`d` operands
therefore **requires instantiating with `max_degree ≥ 2d`**. A caller working at
degree 64 carries a 129-element array and pays a 129-slot `normalize()` even
though the answer has degree 128. That is a property of the fixed-size
representation rather than of the multiplication, and it is the reason the
second baseline exists: it is the cost `libs/poly` pays for being stack-only.

## Results

Karatsuba over slices versus naive over slices (`k vs slice`). Greater than 1
means Karatsuba wins; the algorithmic question.

| degree | F7 | M31 | Goldilocks |
|---|---|---|---|
| 8 | 0.49× / 1.12× / 1.04× | 0.57× / 1.03× / 0.97× | 0.62× / 0.99× / 0.98× |
| 16 | 0.42× / 0.67× / 0.94× | 0.52× / 0.78× / 0.90× | 0.58× / 0.70× / 0.85× |
| 32 | 0.61× / 0.88× / 1.02× | 0.68× / 0.92× / 0.95× | 0.82× / 0.98× / 1.07× |
| 64 | 0.71× / 1.02× / 1.21× | 0.80× / 1.05× / 1.13× | 0.98× / 1.23× / 1.23× |
| 128 | 0.95× / 1.25× / 1.45× | 0.98× / 1.20× / 1.34× | 1.28× / 1.54× / 1.44× |
| 256 | 1.31× / 1.71× / 1.96× | 1.44× / 1.79× / 1.86× | 1.84× / 2.06× / 2.01× |

Each cell is `crossover 8 / 16 / 32`.

The same measurement against the library as shipped (`k vs lib`), which is what a
caller would actually observe:

| degree | F7 | M31 | Goldilocks |
|---|---|---|---|
| 8 | 0.63× / 1.16× / 1.16× | 0.51× / 1.03× / 0.95× | 0.69× / 1.07× / 1.18× |
| 16 | 0.65× / 0.91× / 1.43× | 0.73× / 1.10× / 1.19× | 0.96× / 1.10× / 1.28× |
| 32 | 0.68× / 0.97× / 1.22× | 0.80× / 1.09× / 1.09× | 0.94× / 1.24× / 1.30× |
| 64 | 0.83× / 1.15× / 1.37× | 0.95× / 1.22× / 1.33× | 1.10× / 1.46× / 1.40× |
| 128 | 1.14× / 1.47× / 1.76× | 1.26× / 1.45× / 1.69× | 1.52× / 1.86× / 1.74× |
| 256 | 1.46× / 1.85× / 2.02× | 1.60× / 1.93× / 2.12× | 1.96× / 2.26× / 2.38× |

Absolute figures at the crossover that matters most (32), Goldilocks, minimum of
seven: degree 64 is 11098 ns naive-over-slices versus 9013 ns Karatsuba; degree
256 is 166732 ns versus 82913 ns.

**Variability.** The tables above are one representative run. Between runs the
ratios move by a few percent even after taking a minimum of seven — degree 8 over
F7 at crossover 32 read 1.16× on one run and 1.18× on the next. Treat differences
under roughly 10% as unresolved. The degree-256 column, at 1.9–2.4×, is the only
part of the table that is stable enough to plan against, and it is also the part
no current caller reaches.

## What the numbers say

**The textbook crossover of 8 is the worst of the three in this range.** With 8,
Karatsuba loses at every degree up to 128 in all three fields, and only reaches
1.31–1.84× at degree 256. The crossover where the recursion stops is a
performance parameter, not a constant, and 8 is tuned for machines where a field
operation was expensive relative to bookkeeping.

**The real crossover is near 32.** With it, Karatsuba is at parity from degree 32
and clearly ahead from 64 — 1.13–1.23× against naive-over-slices, 1.33–1.40×
against the library.

**Most of the win against the library is the representation, not the algorithm.**
At degree 256 over Goldilocks, `k vs slice` is 2.01× while `k vs lib` is 2.38×.
The gap between them is what the comptime-sized array and `normalize()` cost. A
Karatsuba inside `Polynomial` would inherit that cost; a Karatsuba over slices,
where four call sites already work, would not.

**The gain grows with degree and does not plateau in the measured range.** 1.21×
at 64, 1.45× at 128, 1.96× at 256. Nothing here contradicts the sub-cubic
warrant; the asymptotic case simply starts above what this library exercises.

## The finding that decides the question, restated

The first version of this section concluded: *nothing in this repository consumes
`zig-poly`, so do not optimise it.* That conclusion is wrong, and the reason is
worth recording because the measurement that refuted it took one command.

Seven of the seventeen libraries have zero internal consumers:

| library | internal consumers |
|---|---|
| algebra-traits, field | 7 each |
| hash | 3 |
| merkle, curve, parallel | 2 each |
| bigint, ntt, pairing, transcript | 1 each |
| rng, binary-field, **poly**, linalg, fri, kzg, serialization | **0** |

`linalg` and `serialization` sit in the zero set alongside `poly`, and nobody
would argue either should be removed: they are general-purpose utilities whose
consumers are outside this tree, which is the design of a modular ecosystem. So
*"no internal consumer"* is the **design**, not a defect, and citing it to decline
work would decline half the repository on a criterion none of it signed up for.
The measurement stands; the conclusion drawn from it was the wrong shape.

**What the four copies actually report is an API gap, not an absence of
consumers.** `zig-poly` exposes `Polynomial(F, max_degree)` on a comptime-sized
array. Every real call site in this tree holds a runtime-length slice, so four of
them wrote their own evaluation rather than force their data into a shape the
library does not offer:

| Site | Function | Operates on |
|---|---|---|
| `libs/algebra-traits/src/traits.zig:1066` | `evalPolyHorner` | `[]const F`, with `FieldTrait(F).assert()` |
| `libs/binary-field/src/sumcheck.zig:244` | `evalPoly` | `[]const F`, private |
| `libs/binary-field/src/pack.zig:59` | `evalPoly` | `[]const F`, private |
| `libs/kzg/src/root.zig:106` | `evaluate` | `[]const Fr` |

They agree today (`libs/poly/tests/horner_parity.zig` checks the reachable three),
so this is latent divergence rather than a live bug. The finding is that they
exist at all: **for a general-purpose library, "callers route around you" is an
API report, and it is louder than any internal-consumer count.** Four copies are
three names for one operation, two of them private and therefore invisible to any
cross-library test.

## Conclusion

**The measurement stands on its own; what it does not do is settle whether the
work is worth doing, because the arithmetic was never the question.**

Karatsuba at crossover 32 is 1.13–1.23× against naive-over-slices from degree 64,
1.34–1.45× at 128, and 1.86–2.04× at 256, against an externally verified warrant.
Whether that matters depends entirely on the regime a general-purpose consumer
would hold, and this repository does not know it — its own tests use degrees 0,
8, 16 and 64, which is the range where the win is parity to 1.2×. So the honest
statement is *conditional*: Karatsuba pays above degree ~64, and the crossover
that pays is 32 rather than the textbook 8.

The prerequisite is therefore the API, not the optimisation: a slice-based
evaluation and product, with the four duplicated sites converging on it, would
make the measured regime reachable by anyone. That is a change to what `zig-poly`
*offers*, and it is decided on its own merits — for a general-purpose library the
question is whether the API covers the shapes its callers hold, not whether
anybody inside this tree happens to hold them yet.

## How to re-derive these figures

```bash
zig build poly-mul-bench          # crossover 32, the value in libs/poly/bench/mul.zig
```

The crossover is a comptime constant at the top of that file; edit it and rebuild
to reproduce the other two columns. The benchmark prints `NO` instead of a ratio
if the Karatsuba result disagrees with the library's, so a green table is a table
whose numbers meant something.
