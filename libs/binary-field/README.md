# zig-binary-field

Binary (characteristic-2) Galois fields for Zig. GF(2^n) arithmetic with tower field construction, hardware-accelerated carry-less multiplication, and Binius-style polynomial commitment schemes.

## Features

- **Generic `BinaryField(n)` type** — GF(2^n) for any n
- **Tower field construction** — Wiedemann tower: GF(2) → GF(4) → GF(16) → ... → GF(2^128)
- **CLMUL hardware acceleration** — x86 ADX/BMI2, ARM PMULL carry-less multiply
- **Multilinear polynomial evaluation** — packed MLE (Binius packing)
- **Sum-check protocol** — binary-field sumcheck prover/verifier
- **FRI-PCS** — committed polynomial evaluation over binary fields
- **Gadgets** — adder, bitpack, rangecheck, compare
- **Constraint DSL** — for building arithmetic circuits

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zig_binary_field = .{
        .path = "path/to/zig-algebra-core/zig-binary-field",
    },
},
```

Then in your `build.zig`:

```zig
const bf = b.dependency("zig_binary_field", .{});
exe.root_module.addImport("zig-binary-field", bf.module("zig-binary-field"));
```

## Quick Start

```zig
const zbf = @import("zig-binary-field");

// GF(2^8) — used in AES, Reed-Solomon
const GF256 = zbf.BinaryField(8);

// Basic arithmetic (XOR for add, CLMUL + reduction for mul)
const a = GF256.fromInt(0x53);
const b = GF256.fromInt(0xCA);
const sum = a.add(b);   // XOR
const prod = a.mul(b);  // carry-less multiply + reduction
const inv = a.inv();    // GF(2^8) inversion

// Tower field: GF(2^128) for Ghash/AES-GCM
const GF128 = zbf.TowerField(128);
```

## Running Tests

```bash
zig build test
```

## Design Notes

- Addition is XOR (no carry)
- Multiplication uses carry-less multiply (PCLMULQDQ on x86, PMULL on ARM) with polynomial reduction
- Tower fields use the Wiedemann construction for efficient extension
- Used by zig-stark's Binius stack for binary-field STARKs

## License

MIT OR Apache-2.0
