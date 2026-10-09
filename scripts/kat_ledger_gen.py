#!/usr/bin/env python3
"""Generate docs/kat_ledger.json from the tree plus the recorded provenances.

The provenance map below is the part a human writes: for each entry point,
either the external implementation its vector comes from, or the reason no
external vector applies. Anything not in the map gets a reason that says so
explicitly rather than a blank, because a blank is what the gate refuses.
"""

import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from kat_verify import VERBS, PUB_FN, derive  # noqa: E402

P = "libs/pairing/src/"
PY_ECC = "py_ecc 8.0.0 (py_ecc.bn128 and py_ecc.optimized_bn128, agreeing coefficient for coefficient)"

PROVENANCE = {
    # ---- pairing: every implementation pinned, or built on one that is ----
    f"{P}bn254_tower.zig:pairing": {"vector": f"{PY_ECC}; test at {P}bn254_tower.zig:895"},
    f"{P}bn254_tower.zig:pairingSparse": {"reason": "no vector of its own; pinned to pairing() by the equality tests in the same file (pairingSparse == pairingDense on the generators, pairing == the py_ecc value)"},
    f"{P}bn254_tower.zig:pairingDense": {"reason": "no vector of its own; tested equal to pairingSparse in the same file, which is pinned to py_ecc"},
    f"{P}bn254_tower.zig:pairingChecked": {"reason": "same value as pairing() plus the subgroup guard; no independent implementation to differential against"},
    f"{P}bn254_tower.zig:pairingSparseChecked": {"reason": "pairingSparse plus the subgroup guard; no differential of its own"},
    f"{P}bn254_tower.zig:pairingDenseChecked": {"reason": "pairingDense plus the subgroup guard; no differential of its own"},
    f"{P}bn254_tower.zig:finalExponentiate": {"reason": "the standard (p^12-1)/r exponentiation; the value it produces is the one py_ecc pins at bn254_tower.zig:895"},
    f"{P}bn254_tower.zig:finalExponentiateSplit": {"reason": "the split form of the same exponentiation, tested equal to the unsplit one in the same file"},
    f"{P}bn254.zig:pairing": {"vector": f"{PY_ECC}, converted to this file's tower by t -> w^-1; test at {P}bn254.zig"},
    f"{P}bn254_direct.zig:pairing": {"vector": f"{PY_ECC}, converted to this ring by t -> w^2; test at {P}bn254_direct.zig"},
    f"{P}bls12_381.zig:pairing": {"vector": "EIP-197 known-answer value for the canonical generators; test in libs/pairing/src/bls12_381.zig"},
    f"{P}bls12_381.zig:millerLoop": {"reason": "the raw loop feeding pairing(), which carries the EIP-197 value; the loop itself has no separate external anchor"},
    f"{P}bls12_381.zig:finalExpSplit": {"reason": "the split form of the (p^12-1)/r exponentiation, tested equal to the unsplit form in the same file"},
    f"{P}bn254.zig:millerLoop": {"reason": "the raw loop feeding pairing(), which is pinned to py_ecc; the loop itself has no separate external anchor"},
    f"{P}bn254.zig:millerLoopChecked": {"reason": "the checked form of the same loop; pinned through pairing() to py_ecc"},
    f"{P}bn254_tower.zig:millerLoop": {"reason": "the raw loop feeding pairing(), which is pinned to py_ecc at bn254_tower.zig:895; the sparse loop is also checked against the dense reference in the same file"},
    f"{P}bn254_tower.zig:millerLoopChecked": {"reason": "the checked form of the same loop, adding the subgroup guard"},
    f"{P}bn254_tower.zig:millerLoopPair": {"reason": "the num/den form of the same loop; pinned through pairing() to py_ecc"},
    f"{P}bn254_tower.zig:millerLoopPairChecked": {"reason": "the checked num/den form; pinned through pairing() to py_ecc"},
    f"{P}bn254_direct.zig:millerLoopPair": {"reason": "the raw loop feeding pairing(), which is pinned to py_ecc; the loop itself has no separate external anchor"},
    f"{P}bn254_direct.zig:millerLoopPairChecked": {"reason": "the checked form of the same loop; pinned through pairing() to py_ecc"},
    f"{P}bn254_direct.zig:finalExponentiate": {"reason": "the standard (p^12-1)/r exponentiation; the value it produces is the one py_ecc pins in the test at the end of this file"},
    # ---- kzg: a differential exists ----
    "libs/kzg/src/root.zig:commit": {"vector": f"{PY_ECC} (differential at libs/kzg/src/root.zig:305)"},
    "libs/kzg/src/root.zig:prove": {"vector": f"{PY_ECC} (differential at libs/kzg/src/root.zig:305)"},
    "libs/kzg/src/root.zig:verify": {"vector": f"{PY_ECC} (differential at libs/kzg/src/root.zig:305)"},
    # ---- merkle: the Bitcoin vectors pin the tree path ----
    "libs/merkle/src/merkle_tree.zig:prove": {"vector": "Bitcoin Merkle vectors from an independent implementation; tests at libs/merkle/tests/bitcoin_merkle_test.zig:48"},
    "libs/merkle/src/merkle_tree.zig:verify": {"vector": "Bitcoin Merkle vectors from an independent implementation; tests at libs/merkle/tests/bitcoin_merkle_test.zig:48"},
    "libs/merkle/src/merkle_tree.zig:verifyPath": {"vector": "Bitcoin Merkle vectors from an independent implementation; tests at libs/merkle/tests/bitcoin_merkle_test.zig:48"},
    "libs/merkle/src/merkle_tree.zig:verifyPath#2": {"reason": "the free-function form of the same path check, over a MerkleProof; pinned through MerkleTree.verifyPath, which the Bitcoin vectors exercise"},
    "libs/merkle/src/merkle_tree.zig:verifyHashed": {"reason": "a thin wrapper over verifyPath, which the Bitcoin vectors pin"},
    "libs/merkle/src/mmr.zig:prove": {"reason": "MMR is this tree's own construction; no independent implementation exists to pin it to"},
    "libs/merkle/src/mmr.zig:verify": {"reason": "MMR is this tree's own construction; no independent implementation exists to pin it to"},
    "libs/merkle/src/sparse_merkle.zig:prove": {"reason": "sparse Merkle is this tree's own construction; no independent implementation exists to pin it to"},
    "libs/merkle/src/sparse_merkle.zig:verify": {"reason": "sparse Merkle is this tree's own construction; no independent implementation exists to pin it to"},
    "libs/merkle/src/sparse_merkle.zig:verifyNonMembership": {"reason": "sparse Merkle non-membership is this tree's own construction; no external vector"},
    # ---- curve: the RFC 9380 expansion is pinned, the rest is composition ----
    "libs/curve/src/hash_to_curve.zig:hashToField": {"vector": "RFC 9380 expand_message_xmd vector; test at libs/curve/src/hash_to_curve.zig:269"},
    "libs/curve/src/hash_to_curve.zig:hashToCurve": {"reason": "suite-to-curve composes the pinned expansion and the SvdW map; no end-to-end external vector for this entry point"},
    "libs/curve/src/hash_to_curve.zig:hashToCurveWithCofactor": {"reason": "the cofactor variant of a composition already covered by hashToCurve's parts"},
    "libs/curve/src/hash_to_curve.zig:mapToCurveSvdW": {"reason": "SvdW is the RFC 9380 Section 6.6.1 map; the test vectors here are this implementation's own, and the expansion feeding it is pinned"},
    "libs/curve/src/hash_to_curve_derive.zig:hashToPoint": {"reason": "a thin wrapper over hashToCurve; no vector of its own"},
    "libs/curve/src/msm.zig:msm": {"reason": "no external vector; msm is checked against naive multi-scalar multiplication in the same library, and its inputs are treated as public"},
    # ---- field: IPA, and the stub the Known Gaps already record ----
    "libs/field/src/ipa.zig:commit": {"reason": "no external vector; the IPA commitment is this tree's own construction over field elements used as pseudo-generators"},
    "libs/field/src/ipa.zig:prove": {"reason": "no external vector for the opening proof; the Known Gaps already record that verify is a stub and verifyWithCommitment is the working path"},
    "libs/field/src/ipa.zig:verify": {"reason": "KNOWN GAP: a stub returning error.Unsupported (AGENTS.md Known Gaps); only verifyWithCommitment works. A stub needs no vector yet, and this row is where that stops being invisible"},
    "libs/field/src/ipa.zig:verifyWithCommitment": {"reason": "no external vector; the challenges inside are a local SHA-256 of (L, R, round), which SECURITY.md records is not a Fiat-Shamir session"},
    # ---- fri, kzg's siblings, binary-field's protocols: soundness, not values ----
    "libs/fri/src/root.zig:prove": {"reason": "FRI is soundness-tested against a cheating prover in the same library; there is no independent FRI implementation here to pin values to"},
    "libs/fri/src/root.zig:proveOn": {"reason": "the same loop over a named domain; proven by the same soundness tests"},
    "libs/fri/src/root.zig:verify": {"reason": "soundness-tested against a cheating prover; no external vector"},
    "libs/fri/src/root.zig:verifyOn": {"reason": "the same verifier over a named domain; no external vector"},
    "libs/hash/src/blake3.zig:deriveKey": {"reason": "the module's other known-answer vectors come from the reference implementation's test vectors; derive_key has no vector of its own in this tree"},
    "libs/transcript/src/root.zig:challengeBytes": {"reason": "challenges are this tree's own transcript construction; there is no external specification of it to pin values to"},
    "libs/transcript/src/root.zig:challengeField": {"reason": "no external specification of this transcript; the tests check structure and the 64-byte rule"},
    "libs/transcript/src/root.zig:challengeFieldChecked": {"reason": "the checked form of the same construction; no external specification"},
    "libs/transcript/src/root.zig:challengeFields": {"reason": "several challenges at once from the same construction; no external specification"},
    "libs/transcript/src/root.zig:challengeFrom": {"reason": "the same construction seeded from explicit bytes; no external specification"},
    "libs/transcript/src/root.zig:challengeU64": {"reason": "the same construction reduced to a u64; no external specification"},
}

DEFAULT_REASON = ("no external vector recorded; if one exists this row is wrong and the "
                  "gate is where that gets said")

BINARY_FIELD_REASON = ("binary-field's sum-check and PCS are this tree's own protocols over "
                       "GF(2^n); they are soundness- and completeness-tested in place, and no "
                       "independent implementation exists to differential against. Known gaps "
                       "(F.BITS >= 128 for the challenge field, the Unsafe variants) are "
                       "recorded in AGENTS.md, not here")


def main() -> int:
    root = Path(".")
    tree = derive(root)
    entries = {}
    for rel, names in sorted(tree.items()):
        for name in names:
            key = f"{rel}:{name}"
            if key in PROVENANCE:
                entries[key] = PROVENANCE[key]
            elif rel.startswith("libs/binary-field/"):
                entries[key] = {"reason": BINARY_FIELD_REASON}
            else:
                entries[key] = {"reason": DEFAULT_REASON}
    unaccounted = [k for k, v in entries.items() if v.get("reason") == DEFAULT_REASON]
    if unaccounted:
        print("refusing to write a ledger with default reasons:")
        for k in unaccounted:
            print("  ", k)
        return 1
    ledger = {
        "scope": ("Every `pub fn`, top-level or method, whose name starts with "
                  "pairing, millerLoop, finalExp, commit, prove, verify, open, sign, "
                  "multiScalarMul, msm, hashTo, mapToCurve, derive or challenge, in "
                  "`git ls-files 'libs/*/src/*.zig'` excluding main.zig. The list is "
                  "derived by scripts/kat_verify.py, never written by hand."),
        "measured": "2026-10-09",
        "finding": ("The row this implements recorded 37 entry points. 37 is the "
                    "top-level count; methods inside structs add 30 more (67 total), "
                    "and the excluded set contains Ipa.verify, the stub AGENTS.md lists "
                    "as a known gap. The gate covers both shapes."),
        "entries": entries,
    }
    Path("docs/kat_ledger.json").write_text(
        json.dumps(ledger, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"ledger written: {len(entries)} entry points")
    return 0


if __name__ == "__main__":
    sys.exit(main())
