# Requirements

What a library in this repository has to satisfy, and what holds each claim up.

## How to read this

A row is a **requirement** only if it points at something that can fail. Three
columns carry that:

- **vive en** — where the property is enforced, with a path and a line where
  there is one.
- **lo sostiene** — the test, gate or job that would report it broken. A row
  that cannot name one is not a requirement. It is an **intention**, and it is
  marked as such, because an intention reads exactly like a requirement in a
  table and the difference is only visible if the table says which is which.
- **se rompe si** — the concrete failure this is meant to catch, not a
  restatement of the requirement.

The third question in [the audit](#auditoría-por-librería) is the one this
table exists to answer, and it was added after a fact: a test that has never
been seen to fail has not demonstrated that it carries anything.

Everything here was verified by running it, at the commits cited. Where a
figure could not be established it says so rather than rounding up.

## Requirements

| # | requisito | vive en | lo sostiene | se rompe si |
|---|---|---|---|---|
| 1 | A hash is validated against **external** canonical vectors, never against its own output | `libs/hash/src/root.zig` — "cryptographic hash known-answer vectors" and "Blake3 known-answer vectors, canonical" | 45 BLAKE3 vectors from an independent implementation, plus blake2b/blake2s/sha3 vectors checked against `hashlib` | A vector whose digest was produced by the implementation under test. It pins the bug and passes forever while looking rigorous — which is what the Blake3 entry in that test was, for the whole life of the repository |
| 2 | A hash is differential-tested against a different implementation over the inputs where the structure lives | `examples/fuzz_runner.zig`, nightly `fuzz` job | 3 literal vectors + 17 lengths differential against `std.crypto.hash.Blake3`, including 1023/1024/1025 and 4095/4096/4097 | A single-block vector. BLAKE3's chunk is 1024 bytes, so one short vector never reaches the counter, the cross-chunk chaining, or the parent tree |
| 3 | A check has to be able to be **seen failing** | `examples/fuzz_runner.zig`, and the mutation log below | Watched mutations, not assertions of intent | A gate that was only ever run green. "It passes" is not evidence that it would have caught anything |
| 4 | A check that produces no output is not a check that passed | `.github/workflows/test.yml` — `cross-check` uses `--summary all` | Log names the 34 binaries (17 libraries × 2 targets) | A job that is green, ran for a minute, and says nothing about what it verified. A duration is not a claim about coverage |
| 5 | A round trip proves consistency, not correctness | Nowhere — this is a **known gap**, see the audit | Nothing yet | The characteristic-2 fold bug: `binary-field` round-trips passed on every field in the package while `Sumcheck` rejected **honest** proofs over any odd-characteristic field. It took a 128-bit prime fixture to see it |
| 6 | A test written against the implementation passes by construction | `AGENTS.md` §0 | The 45-vector KAT, which is pinned to literals | Any test whose expected value came from running the code. See requirement 1 |
| 7 | A field large enough to be sound is required by the protocol, not by taste | `libs/binary-field/src/sumcheck.zig` — `MIN_SAFE_BITS = 128` | `error.FieldTooSmall` at 128 bits, and `Prime128` crossing it | A field that is 128 bits without being prime: `2^128 - 1` passes the size gate and is composite, `2^128 - 1 == (2^64 - 1)(2^64 + 1)` |
| 8 | Primality of a fixture's modulus is **proved**, not asserted | `libs/binary-field/src/prime128.zig` — Pocklington certificate | `certifyPrimality()` re-derives `F > √p`, witness `a = 2`, and each prime factor of `F` by a 13-base Miller-Rabin; `isPrimeSmall` is pinned against known primes **and** known composites | A size gate standing in for primality. Also: the first Miller-Rabin here reused the field's `mulmod`, so it computed powers modulo the field's prime instead of modulo `n` and called every small prime composite, `isPrime(97) == false` |
| 9 | An `add`/`sub` distinction is exercised over a field where they differ | `libs/binary-field/src/prime_fixture.zig`, `prime128.zig` | Tests assert the characteristic-2 form and the general form **disagree** on the input, then that the general one is returned | A characteristic-2 test matrix. There the discriminator `2·r` is identically zero, so no test there can distinguish `x - y` from `x + y` |
| 10 | A generalized expression must reduce to the characteristic-2 one where that is correct | `libs/binary-field/src/sumcheck.zig` — `foldLinear` | Single shared definition at all five call sites; the 96 `binary-field` tests pass unchanged, which is the proof it is a no-op in char 2 | Copying the kernel instead of sharing it. The drift happened because five sites had five copies and nothing to keep them in step |
| 11 | Every module that is built **in any target** is also type-checked there | Not satisfied — see the audit | Nothing today | `libs/rng/src/main.zig:44` carried a `std.debug.assert` for the whole life of the repository because no CI job compiled that file. Eight example executables are still built by nobody |
| 12 | A document asserts a **sequence**, not a state | `AGENTS.md` §0 | — | "the hash was broken" expires when the state moves. It was wrong twice in opposite directions: `v0.5.0` was "published" and had not been, then `v0.5.1` was "not published" and had |
| 13 | The audit happens before the tag, not after | `AGENTS.md`, "Releasing: the tag is the gate" | `v0.5.2` shipped with the fix in it; `v0.5.1` shipped a false CHANGELOG paragraph because the tag was taken before anyone read it | Tagging first, which is the natural order and the wrong one. A tag is a photograph; a later correction does not reach it |
| 14 | Who consumes a new capability, and how they learn it has not diverged, is decided **before** it is written | `AGENTS.md` §0 | The circular-domain work has not started; this row is why | Writing the code and then asking who wants it. That is how `binary-field` diverged from its fork for three releases, and the interoperability bug in the Merkle leaf hashing was invisible from both sides because a round trip is self-consistent |

## Mutations watched failing

Requirement 3 is only worth something with the list, so here it is. Every row
was produced by breaking working code on purpose and reading the failure.

| what was broken | gate | what it said |
|---|---|---|
| BLAKE3 ROOT flag in the wrong place | fuzz | `FAIL BLAKE3 vs stdlib at len=1025` |
| BLAKE3 block buffer not zeroed after a full block | fuzz **and** the 45-vector KAT | `FAIL … at len=65`, `Blake3 KAT failed at len=65` |
| `SmallField.add` reduction off by one | fuzz | runner exits non-zero |
| `foldLinear` reverted to `a + t·(a + b)` | fuzz | `Sumcheck: honest 0/80 verified` |
| the same fold | unit tests | 4 tests fail, including both negatives |
| torus generator given order `2^(A-1)` instead of `2^A` | fuzz | `error: OrderTooLarge` |
| the same generator | unit tests | 8 tests fail, including every FRI positive |
| `?windows.HANDLE` reverted to `windows.HANDLE` | `cross-check` | `expected type '*anyopaque', found '@TypeOf(null)'` |

The negative tests that guard these are only load-bearing because each one first
asserts the honest case. The tampered-Sumcheck test in `prime128.zig` falls
under the reverted fold because its first assertion is that the honest proof
verifies; a guard that never fails on the honest path is decoration.

## Auditoría por librería

Three questions, all of them answerable without reading the implementation.
`#1` is external vectors, `#2` a mutation seen failing, `#3` a fork that
diverged. Most rows are "no", and the "no" is the finding: it is what says
where a rewrite would buy something and where it would not.

| library | tests | #1 external vectors | #2 mutation seen failing | #3 forked and diverged |
|---|---|---|---|---|
| `hash` | 19 | **yes** — BLAKE3 45 vectors independent; blake2b/blake2s/sha3 vs `hashlib`; keccak distinct from sha3 | **yes** — 3 mutations | no |
| `field` | 83 | no | **yes** — `add` reduction | no |
| `binary-field` | 96 | **yes** — Pocklington certificate, plus `u256` oracle for `Prime128` | **yes** — sum-check fold, torus generator | **yes** — extracted from `zig-zk/libs/stark/binius/`, diverged three releases, Merkle leaf double-hash invisible from both sides |
| `fri` | 25 | no | **yes** — torus generator | no |
| `pairing` | 57 | **yes** — `py_ecc` (EIP-197) | no | no |
| `rng` | 25 | no | **yes** — `?windows.HANDLE` | no |
| `merkle` | 18 | no | no | no |
| `poly` | 28 | no | no | no |
| `bigint` | 19 | no | no | no |
| `transcript` | 10 | no | no | no |
| `serialization` | 15 | no | no | no |
| `ntt` | 15 | no | no | no |
| `linalg` | 11 | no | no | no |
| `kzg` | 6 | no | no | no |
| `algebra-traits` | 4 | no | no | no |
| `parallel` | 2 | no | no | no |

### What the table says

**Two libraries carry external vectors and one of them is where the worst bug
was.** `hash` has the discipline and was the one that hid a non-BLAKE3 for the
entire life of the repository, because a self-generated vector looks identical
to a real one from the inside. That is the argument for row #1 being a
requirement about *provenance* and not about *having vectors*.

**Fourteen of the seventeen libraries have no external vector at all.** For a field or a matrix
that is defensible: the axioms plus an independent implementation are the test.
For anything that emits a commitment — `merkle`, `transcript`, `kzg`,
`serialization` — it is not, and a wrong commitment is exactly the failure
`binary-field` and `hash` both had.

**Ten libraries have never been seen to fail.** `merkle`, `poly`, `bigint`,
`transcript`, `serialization`, `ntt`, `linalg`, `kzg`, `algebra-traits` and
`parallel`. Every test in them has only ever run green, so the honest statement
about their coverage is that it is unmeasured.

**`parallel` has two tests, and the library reports 2 because only `root.zig`
is a test root.** `timing.zig` has a third (`nowNs is monotonic across a busy
wait`) that the root step never collects, for the reason in requirement 11: a
file that is not imported from the root is lazily unanalysed and its tests do
not run. Nothing in it has ever been executed beyond collection.

**Requirement 11 is unsatisfied, and it is the cheapest thing on this page.**
Eight `libs/*/src/main.zig` are the `root_source_file` of each library's
`example` executable. The root build and every CI job compile the library's
`src/root.zig`; none of them build the examples, and `cross-check` only adds
test artifacts over the root source. They are reachable with
`cd libs/<name> && zig build install` and by nothing else. They are not inert:
`libs/hash/src/main.zig` declares 18 `pub fn` and re-implements the library's
own arithmetic, which is the same failure as requirement 14 — an example
re-implementing instead of importing. Building them costs one `addExecutable`
per library in the existing `cross_register` helper, and it would have caught
the `rng` assert before a release did.

## What this table does not decide

It does not say a library should be rewritten. It says which ones have an
instrument that could tell a rewrite had not broken something. On the evidence
here that is `hash` and `binary-field`, and for `binary-field` the case is not
the tests — it is that its fork diverged for three releases with nothing on
either side able to see it. A rewrite without the requirements and the
instruments written down first would reproduce the fork with extra steps.
