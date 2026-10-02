#!/usr/bin/env python3
"""Count the conditional branches a compiled function contains. It does not classify them.

The claim a docstring makes about constant-time behaviour is a judgement. A judgement
is not auditable: it goes in a comment, a comment is not executed, and nobody can
tell whether it is still true after someone edits the implementation. A count is not
a judgement, and this is what it found: the Montgomery multiplication for BLS12-381
emits ONE conditional jump, while the BigField backend emits eighteen.

**This tool does not classify those jumps, and that is deliberate.** Four attempts
were made and each was wrong in a direction the previous one was not:

  - searching the operand text for any digit reads the `1` in `al` and calls
    `test al, 1` a comparison against a constant
  - looking only at the line before a jump sees a `.loc` and misses the `test`
    that governs it
  - counting `jo` as a data-dependent branch flags a CORRECT mask-select chain,
    whose carry is identical on both paths
  - requiring every operand to be constant stops recognising `cmp r14, 6`

The case that settles it is `test r8, 8`. It is a bitmask applied to a value — the
most data-dependent instruction there is — and its `8` is the mask, not a constant
being compared against. No rule over operand *shape* tells those apart, because in
assembly it is not a question of shape: it is a question of what the instruction
means in the dataflow, which is analysis and not pattern matching. A tool that
classified them would be reporting its own guesses with a measurement's authority.

**So the count is the deliverable, and the reading is a bound.** What a count
supports without classifying:

    0 conditional jumps   the constant-time-with-respect-to-branching claim is
                          ESTABLISHED by this method. A hard fact.
    1                    at most one data-dependent branch. Someone reads that
                          one, once, and records where they looked.
    13, 18               at most thirteen. Anyone claiming constant-time here has
                          to read them. The burden of proof moves.

That is enough to build a gate out of, because a gate cannot decide whether a
function is constant-time and should not pretend to. What it CAN do is require
that every function with a non-zero count carries a recorded judgement with its
provenance — which is the same shape as every other gate in this repository: the
gate checks that a source exists, not that the claim is true.

What this cannot tell, and the report says so: whether a branchless instruction has
constant latency on every microarchitecture, and whether a comparison compiled to
`setcc` leaks through a flag a later instruction reads. That needs a full
disassembly and an audit. This is a floor.

Usage:
    zig build-obj ... -femit-asm=out.s
    python3 tools/asm_probe.py out.s [--symbol SUBSTR] [--json]

Boundary parsing comes from the `.type NAME,@function` directives, and the label may
sit on either side of them and may be quoted or bare. A first version looked only
for a quoted label ending in `:` and found 71 of 428 functions in a real emission;
it said it had found nothing rather than reporting a clean result, which is the only
reason it was caught.
"""

import argparse
import json
import re
import sys
from pathlib import Path

# Conditional jumps, excluding the unconditional ones.
JUMP = re.compile(r"^\s*j[a-z]+\b")
UNCONDITIONAL = re.compile(r"^\s*(jmp\b|ret\b|call\b)")
BRANCHLESS = re.compile(r"^\s*(set[a-z]+|cmov[a-z]*)\b")
# Directives and local labels: not instructions, and they do not clear a pending
# comparison, because a jump can follow several of them.
NOISE = re.compile(r"^\s*\.|^\s*#")
NOISE = re.compile(r"^\s*(\.|\.L|#)")


def split_functions(lines):
    """Yield (name, body_lines) using the `.type ...,@function` directives."""
    bounds = []
    for i, line in enumerate(lines):
        if ".type" in line and "@function" in line:
            parts = line.strip().split()
            if len(parts) >= 2:
                bounds.append((i, parts[1].split("@")[0]))
    for n, (start, name) in enumerate(bounds):
        end = bounds[n + 1][0] if n + 1 < len(bounds) else len(lines)
        yield name, lines[start:end]


def count_in(body):
    """(conditional jumps, branchless instructions) — no classification."""
    jcc = 0
    branchless = 0
    for raw in body:
        line = raw.split("//")[0]
        if not line.strip():
            continue
        if NOISE.match(line):
            continue
        if BRANCHLESS.match(line):
            branchless += 1
            continue
        if UNCONDITIONAL.match(line):
            continue
        if JUMP.match(line):
            jcc += 1
    return jcc, branchless


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("asm", help="the .s file emitted with -femit-asm")
    ap.add_argument("--symbol", help="only functions whose label contains this")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    path = Path(args.asm)
    if not path.exists():
        print(f"asm_probe: {path} not found", file=sys.stderr)
        return 1
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()

    rows = []
    for name, body in split_functions(lines):
        if args.symbol and args.symbol not in name:
            continue
        jcc, branchless = count_in(body)
        if jcc or branchless:
            rows.append((name, jcc, branchless))

    if not rows:
        print(
            f"{path}: no function with a conditional jump or a branchless select was "
            "found. Either the emitter's output shape changed and this instrument is "
            "looking at nothing, or the --symbol filter matched nothing. Both are "
            "failures it must not report as clean.",
            file=sys.stderr,
        )
        return 1

    rows.sort(key=lambda r: (-r[1], r[0]))
    if args.json:
        print(json.dumps(
            [{"function": n, "conditional_jumps": j, "branchless": b} for n, j, b in rows],
            indent=2,
        ))
        return 0

    print(f"{'function':<52} {'jcc':>5} {'br-free':>8}")
    for name, jcc, branchless in rows:
        short = name.strip('",') if len(name) <= 52 else name.strip('",')[:49] + "..."
        print(f"{short:<52} {jcc:>5} {branchless:>8}")

    print(
        "\nA count, not a verdict. This tool does not classify the jumps: an attempt\n"
        "to do so marked a correct mask-select as leaking and a blatant branch on a\n"
        "secret as loop control, and the case that settles it -- `test r8, 8`, a\n"
        "bitmask on a value -- is not distinguishable from `cmp` against 8 by operand\n"
        "shape. Zero is established; one is read once by a person; thirteen is read.\n"
        "It also does not cover latency, nor a flag read after a setcc."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())