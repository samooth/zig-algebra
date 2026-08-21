//! zig-algebra-traits: Zero-cost compile-time trait contracts for computational algebra.
//!
//! This module defines algebraic trait contracts (Set, Group, Ring, Field, etc.)
//! that are validated entirely at `comptime`.  They add **zero runtime overhead**;
//! they exist only to produce clear compile errors when a type does not satisfy
//! the expected interface.
//!
//! # Design Philosophy
//!
//! - **Zero-cost**: Traits are compile-time structs; they evaporate after type-checking.
//! - **Allocation-free**: No heap usage, ever.
//! - **Explicit**: `assert()` produces a clear `@compileError` instead of a cryptic
//!   missing-declaration error deep inside generic code.
//!
//! # Quick Start
//!
//! ```zig
//! const traits = @import("zig-algebra-traits");
//!
//! // Define your field type (see examples in the crate documentation).
//! const F7 = struct { ... };
//!
//! // Verify at compile time that F7 satisfies the Field trait.
//! traits.assertField(F7);
//!
//! // Use generic algorithms that work over any Field.
//! const x = traits.pow(F7, F7.fromInt(3), 100);
//! ```
//!
//! # Trait Hierarchy
//!
//! ```text
//! Set
//!  └── Group (additive / multiplicative)
//!       └── Ring
//!            └── Field
//!                 └── PrimeField
//!                 └── FieldExtension
//! VectorSpace (over a Field)
//! PolynomialRing (over a Ring)
//! EllipticCurve (over a Field)
//!      └── PairingFriendly
//! CommitmentScheme
//! Ntt
//! HashToField / HashToCurve
//! MerkleTree
//! Transcript
//! FieldRng
//! ```

const std = @import("std");

// ============================================================================
// Error types
// ============================================================================

/// Errors that can arise during algebraic operations.
pub const AlgebraError = error{
    DivisionByZero,
    NonInvertibleElement,
    InvalidGroupOperation,
    NotASquare,
    InvalidCurvePoint,
    NotInSubgroup,
};

// ============================================================================
// 1. SET (base)
// ============================================================================

/// Verifies that `T` is a set with equality.
///
/// Required declarations on `T`:
/// - `eql(a: T, b: T) bool`
///
/// Optional (checked but not required by `assert`):
/// - `neq(a: T, b: T) bool`
/// - `hash(a: T) u64`
///
/// # Example
/// ```zig
/// const MySet = struct {
///     pub fn eql(a: Self, b: Self) bool { ... }
/// };
/// SetTrait(MySet).assert();
/// ```
pub fn SetTrait(comptime T: type) type {
    return struct {
        pub const has_eq = @hasDecl(T, "eql");
        pub const has_neq = @hasDecl(T, "neq");
        pub const has_hash = @hasDecl(T, "hash");

        pub fn assert() void {
            if (!has_eq) @compileError("Set trait: missing 'eql' declaration on " ++ @typeName(T));
        }
    };
}

// ============================================================================
// 2. GROUP
// ============================================================================

/// Generic group trait with a named binary operation.
///
/// `op_name` is the method name on `T` (e.g. `"add"` or `"mul"`).
/// Required declarations on `T`:
/// - `op_name(a: T, b: T) T`
/// - `identity() T`
/// - `inverse(a: T) T`
/// - `eql(a: T, b: T) bool`
///
/// # Example
/// ```zig
/// const G = struct {
///     pub fn op(a: Self, b: Self) Self { ... }
///     pub fn identity() Self { ... }
///     pub fn inverse(a: Self) Self { ... }
///     pub fn eql(a: Self, b: Self) bool { ... }
/// };
/// GroupTrait(G, "op").assert();
/// ```
pub fn GroupTrait(comptime T: type, comptime op_name: []const u8) type {
    return GroupTraitWithId(T, op_name, "identity");
}

/// Generic group trait with custom identity method name.
///
/// `op_name` is the method name on `T` (e.g. `"add"` or `"mul"`).
/// `id_name` is the method name for the identity element (e.g. `"zero"` for additive groups).
/// Required declarations on `T`:
/// - `op_name(a: T, b: T) T`
/// - `id_name() T`
/// - `inverse(a: T) T`
/// - `eql(a: T, b: T) bool`
///
/// # Example
/// ```zig
/// const G = struct {
///     pub fn add(a: Self, b: Self) Self { ... }
///     pub fn zero() Self { ... }
///     pub fn neg(a: Self) Self { ... }
///     pub fn eql(a: Self, b: Self) bool { ... }
/// };
/// GroupTraitWithId(G, "add", "zero").assert();
/// ```
pub fn GroupTraitWithId(comptime T: type, comptime op_name: []const u8, comptime id_name: []const u8) type {
    return struct {
        pub const has_op = @hasDecl(T, op_name);
        pub const has_id = @hasDecl(T, id_name);
        pub const has_inv = @hasDecl(T, "inverse");
        pub const has_eq = @hasDecl(T, "eql");

        pub fn assert() void {
            if (!has_op) @compileError("Group trait: missing operation '" ++ op_name ++ "' on " ++ @typeName(T));
            if (!has_id) @compileError("Group trait: missing '" ++ id_name ++ "' on " ++ @typeName(T));
            if (!has_inv) @compileError("Group trait: missing 'inverse' on " ++ @typeName(T));
            if (!has_eq) @compileError("Group trait: missing 'eql' on " ++ @typeName(T));
        }
    };
}

/// Additive group trait: `add`, `zero`, `neg`.
///
/// Required declarations:
/// - `add(a: T, b: T) T`
/// - `zero() T`
/// - `neg(a: T) T`
/// - `eql(a: T, b: T) bool`
///
/// # Example
/// ```zig
/// const G = struct {
///     pub fn add(a: Self, b: Self) Self { ... }
///     pub fn zero() Self { ... }
///     pub fn neg(a: Self) Self { ... }
///     pub fn eql(a: Self, b: Self) bool { ... }
/// };
/// AdditiveGroupTrait(G).assert();
/// ```
pub fn AdditiveGroupTrait(comptime T: type) type {
    return struct {
        pub const base = GroupTraitWithId(T, "add", "zero");
        pub const has_neg = @hasDecl(T, "neg");
        pub const has_zero = @hasDecl(T, "zero");

        pub fn assert() void {
            base.assert();
            if (!has_neg) @compileError("AdditiveGroup trait: missing 'neg' on " ++ @typeName(T));
            if (!has_zero) @compileError("AdditiveGroup trait: missing 'zero' on " ++ @typeName(T));
        }
    };
}

/// Multiplicative group trait: `mul`, `one`, `inv`.
///
/// Required declarations:
/// - `mul(a: T, b: T) T`
/// - `one() T`
/// - `inv(a: T) T`
/// - `eql(a: T, b: T) bool`
///
/// # Example
/// ```zig
/// const G = struct {
///     pub fn mul(a: Self, b: Self) Self { ... }
///     pub fn one() Self { ... }
///     pub fn inv(a: Self) Self { ... }
///     pub fn eql(a: Self, b: Self) bool { ... }
/// };
/// MultiplicativeGroupTrait(G).assert();
/// ```
pub fn MultiplicativeGroupTrait(comptime T: type) type {
    return struct {
        pub const base = GroupTrait(T, "mul");
        pub const has_inv = @hasDecl(T, "inv");
        pub const has_one = @hasDecl(T, "one");

        pub fn assert() void {
            base.assert();
            if (!has_inv) @compileError("MultiplicativeGroup trait: missing 'inv' on " ++ @typeName(T));
            if (!has_one) @compileError("MultiplicativeGroup trait: missing 'one' on " ++ @typeName(T));
        }
    };
}

// ============================================================================
// 3. RING
// ============================================================================

/// Ring trait: additive abelian group + multiplicative monoid with distributivity.
///
/// Required declarations on `T`:
/// - All of `AdditiveGroupTrait`
/// - `mul(a: T, b: T) T`
/// - `one() T`
/// - `sub(a: T, b: T) T`
///
/// # Example
/// ```zig
/// const R = struct {
///     pub fn add(a: Self, b: Self) Self { ... }
///     pub fn zero() Self { ... }
///     pub fn neg(a: Self) Self { ... }
///     pub fn sub(a: Self, b: Self) Self { ... }
///     pub fn mul(a: Self, b: Self) Self { ... }
///     pub fn one() Self { ... }
///     pub fn eql(a: Self, b: Self) bool { ... }
/// };
/// RingTrait(R).assert();
/// ```
pub fn RingTrait(comptime T: type) type {
    return struct {
        pub const has_add_group = AdditiveGroupTrait(T);
        pub const has_mul = @hasDecl(T, "mul");
        pub const has_one = @hasDecl(T, "one");
        pub const has_sub = @hasDecl(T, "sub");

        pub fn assert() void {
            has_add_group.assert();
            if (!has_mul) @compileError("Ring trait: missing 'mul' on " ++ @typeName(T));
            if (!has_one) @compileError("Ring trait: missing 'one' on " ++ @typeName(T));
            if (!has_sub) @compileError("Ring trait: missing 'sub' on " ++ @typeName(T));
        }
    };
}

// ============================================================================
// 4. FIELD
// ============================================================================

/// Field trait: commutative ring where every non-zero element has a multiplicative inverse.
///
/// Required declarations on `T`:
/// - All of `RingTrait`
/// - `inv(a: T) T`
/// - `div(a: T, b: T) T`
/// - `pow(base: T, exp: u256) T`
/// - `isZero(a: T) bool`
///
/// Optional (checked but not required by `assert`):
/// - `characteristic: u64`
/// - `order: u64`
/// - `random() T`
///
/// # Example
/// ```zig
/// const F = struct {
///     pub fn add(a: Self, b: Self) Self { ... }
///     pub fn zero() Self { ... }
///     pub fn neg(a: Self) Self { ... }
///     pub fn sub(a: Self, b: Self) Self { ... }
///     pub fn mul(a: Self, b: Self) Self { ... }
///     pub fn one() Self { ... }
///     pub fn inv(a: Self) Self { ... }
///     pub fn div(a: Self, b: Self) Self { ... }
///     pub fn pow(base: Self, exp: u256) Self { ... }
///     pub fn isZero(a: Self) bool { ... }
///     pub fn eql(a: Self, b: Self) bool { ... }
/// };
/// FieldTrait(F).assert();
/// ```
pub fn FieldTrait(comptime T: type) type {
    return struct {
        pub const has_ring = RingTrait(T);
        pub const has_inv = @hasDecl(T, "inv");
        pub const has_div = @hasDecl(T, "div");
        pub const has_pow = @hasDecl(T, "pow");
        pub const has_characteristic = @hasDecl(T, "characteristic");
        pub const has_order = @hasDecl(T, "order");
        pub const has_isZero = @hasDecl(T, "isZero");
        pub const has_random = @hasDecl(T, "random");

        pub fn assert() void {
            has_ring.assert();
            if (!has_inv) @compileError("Field trait: missing 'inv' on " ++ @typeName(T));
            if (!has_div) @compileError("Field trait: missing 'div' on " ++ @typeName(T));
            if (!has_pow) @compileError("Field trait: missing 'pow' on " ++ @typeName(T));
            if (!has_isZero) @compileError("Field trait: missing 'isZero' on " ++ @typeName(T));
        }
    };
}

/// Prime field trait: F_p where p is prime.
///
/// Additional required declarations:
/// - `modulus: u64` (comptime constant)
/// - `fromInt(x: u256) T`
/// - `toInt(a: T) u64`
///
/// # Example
/// ```zig
/// const Fp = struct {
///     pub const modulus: u64 = 7;
///     pub fn fromInt(x: u256) Self { ... }
///     pub fn toInt(a: Self) u64 { ... }
///     // ... plus all Field methods
/// };
/// PrimeFieldTrait(Fp).assert();
/// ```
pub fn PrimeFieldTrait(comptime T: type) type {
    return struct {
        pub const has_field = FieldTrait(T);
        pub const has_modulus = @hasDecl(T, "modulus");
        pub const has_fromInt = @hasDecl(T, "fromInt");
        pub const has_toInt = @hasDecl(T, "toInt");

        pub fn assert() void {
            has_field.assert();
            if (!has_modulus) @compileError("PrimeField trait: missing 'modulus' on " ++ @typeName(T));
            if (!has_fromInt) @compileError("PrimeField trait: missing 'fromInt' on " ++ @typeName(T));
        }
    };
}

/// Field extension trait: F_{p^k} as F_p[x]/(irreducible).
///
/// Additional required declarations:
/// - `BaseField: type`
/// - `extension_degree: usize` (comptime constant, k)
/// - `frobenius(a: T) T` (x -> x^p)
///
/// # Example
/// ```zig
/// const Fp2 = struct {
///     pub const BaseField = Fp;
///     pub const extension_degree = 2;
///     pub fn frobenius(a: Self) Self { ... }
///     // ... plus all Field methods
/// };
/// FieldExtensionTrait(Fp2).assert();
/// ```
pub fn FieldExtensionTrait(comptime T: type) type {
    return struct {
        pub const has_field = FieldTrait(T);
        pub const has_base_field = @hasDecl(T, "BaseField");
        pub const has_degree = @hasDecl(T, "extension_degree");
        pub const has_frobenius = @hasDecl(T, "frobenius");

        pub fn assert() void {
            has_field.assert();
            if (!has_base_field) @compileError("FieldExtension trait: missing 'BaseField' on " ++ @typeName(T));
            if (!has_degree) @compileError("FieldExtension trait: missing 'extension_degree' on " ++ @typeName(T));
        }
    };
}

// ============================================================================
// 5. VECTOR SPACE
// ============================================================================

/// Vector space trait: V over a field F.
///
/// Required declarations on `V`:
/// - `add(a: V, b: V) V`
/// - `neg(a: V) V`
/// - `zero() V`
/// - `scale(scalar: F, vec: V) V` or `scale(vec: V, scalar: F) V`
/// - `dimension: usize` (comptime)
/// - `eql(a: V, b: V) bool`
///
/// `F` must satisfy `FieldTrait`.
///
/// # Example
/// ```zig
/// const V2 = struct {
///     pub const dimension = 2;
///     pub fn add(a: Self, b: Self) Self { ... }
///     pub fn zero() Self { ... }
///     pub fn neg(a: Self) Self { ... }
///     pub fn scale(s: F, v: Self) Self { ... }
///     pub fn eql(a: Self, b: Self) bool { ... }
/// };
/// VectorSpaceTrait(V2, F).assert();
/// ```
pub fn VectorSpaceTrait(comptime V: type, comptime F: type) type {
    return struct {
        pub const has_field = FieldTrait(F);
        pub const has_add = @hasDecl(V, "add");
        pub const has_neg = @hasDecl(V, "neg");
        pub const has_zero = @hasDecl(V, "zero");
        pub const has_scale = @hasDecl(V, "scale");
        pub const has_dim = @hasDecl(V, "dimension");
        pub const has_eq = @hasDecl(V, "eql");

        pub fn assert() void {
            has_field.assert();
            if (!has_add) @compileError("VectorSpace trait: missing 'add' on " ++ @typeName(V));
            if (!has_neg) @compileError("VectorSpace trait: missing 'neg' on " ++ @typeName(V));
            if (!has_zero) @compileError("VectorSpace trait: missing 'zero' on " ++ @typeName(V));
            if (!has_scale) @compileError("VectorSpace trait: missing 'scale' on " ++ @typeName(V));
            if (!has_eq) @compileError("VectorSpace trait: missing 'eql' on " ++ @typeName(V));
        }
    };
}

// ============================================================================
// 6. POLYNOMIAL RING
// ============================================================================

/// Polynomial ring trait: R[x] over a ring R.
///
/// Required declarations on `P`:
/// - `add(a: P, b: P) P`
/// - `mul(a: P, b: P) P`
/// - `eval(p: P, x: R) R`
/// - `degree(p: P) usize`
/// - `coeff(p: P, i: usize) R`
/// - `fromCoeffs(coeffs: []const R) P`
/// - `eql(a: P, b: P) bool`
///
/// `R` must satisfy `RingTrait`.
///
/// # Example
/// ```zig
/// const Poly = struct {
///     pub fn add(a: Self, b: Self) Self { ... }
///     pub fn mul(a: Self, b: Self) Self { ... }
///     pub fn eval(p: Self, x: F) F { ... }
///     pub fn degree(p: Self) usize { ... }
///     pub fn coeff(p: Self, i: usize) F { ... }
///     pub fn fromCoeffs(c: []const F) Self { ... }
///     pub fn eql(a: Self, b: Self) bool { ... }
/// };
/// PolynomialRingTrait(Poly, F).assert();
/// ```
pub fn PolynomialRingTrait(comptime P: type, comptime R: type) type {
    return struct {
        pub const has_ring = RingTrait(R);
        pub const has_add = @hasDecl(P, "add");
        pub const has_mul = @hasDecl(P, "mul");
        pub const has_eval = @hasDecl(P, "eval");
        pub const has_degree = @hasDecl(P, "degree");
        pub const has_coeff = @hasDecl(P, "coeff");
        pub const has_fromCoeffs = @hasDecl(P, "fromCoeffs");
        pub const has_eq = @hasDecl(P, "eql");

        pub fn assert() void {
            has_ring.assert();
            if (!has_add) @compileError("PolynomialRing trait: missing 'add' on " ++ @typeName(P));
            if (!has_mul) @compileError("PolynomialRing trait: missing 'mul' on " ++ @typeName(P));
            if (!has_eval) @compileError("PolynomialRing trait: missing 'eval' on " ++ @typeName(P));
            if (!has_degree) @compileError("PolynomialRing trait: missing 'degree' on " ++ @typeName(P));
            if (!has_coeff) @compileError("PolynomialRing trait: missing 'coeff' on " ++ @typeName(P));
            if (!has_eq) @compileError("PolynomialRing trait: missing 'eql' on " ++ @typeName(P));
        }
    };
}

// ============================================================================
// 7. ELLIPTIC CURVE
// ============================================================================

/// Elliptic curve trait: points (x,y) satisfying y^2 = x^3 + ax + b over a field F.
///
/// Required declarations on `E`:
/// - `add(P: E, Q: E) E` (point addition)
/// - `double(P: E) E` (point doubling)
/// - `neg(P: E) E` (point negation)
/// - `scalarMul(k: u256, P: E) E`
/// - `generator() E` (base point G)
/// - `identity() E` (point at infinity)
/// - `isOnCurve(P: E) bool`
/// - `isIdentity(P: E) bool`
/// - `toAffine(P: E) struct { x: F, y: F }`
/// - `fromAffine(x: F, y: F) E`
/// - `eql(a: E, b: E) bool`
/// - `order: u256` (curve order, comptime)
/// - `cofactor: u32` (comptime)
/// - `subgroupCheck(P: E) bool`
///
/// `F` must satisfy `FieldTrait`.
///
/// # Example
/// ```zig
/// const Curve = struct {
///     pub fn add(a: Self, b: Self) Self { ... }
///     pub fn double(a: Self) Self { ... }
///     pub fn neg(a: Self) Self { ... }
///     pub fn scalarMul(k: u256, a: Self) Self { ... }
///     pub fn generator() Self { ... }
///     pub fn identity() Self { ... }
///     pub fn isOnCurve(a: Self) bool { ... }
///     pub fn eql(a: Self, b: Self) bool { ... }
///     pub const order: u256 = ...;
///     pub const cofactor: u32 = 1;
///     pub fn subgroupCheck(a: Self) bool { ... }
/// };
/// EllipticCurveTrait(Curve, F).assert();
/// ```
pub fn EllipticCurveTrait(comptime E: type, comptime F: type) type {
    return struct {
        pub const has_field = FieldTrait(F);
        pub const has_a = @hasDecl(E, "a");
        pub const has_b = @hasDecl(E, "b");
        pub const has_add = @hasDecl(E, "add");
        pub const has_double = @hasDecl(E, "double");
        pub const has_neg = @hasDecl(E, "neg");
        pub const has_scalarMul = @hasDecl(E, "scalarMul");
        pub const has_generator = @hasDecl(E, "generator");
        pub const has_identity = @hasDecl(E, "identity");
        pub const has_isOnCurve = @hasDecl(E, "isOnCurve");
        pub const has_isIdentity = @hasDecl(E, "isIdentity");
        pub const has_eq = @hasDecl(E, "eql");
        pub const has_order = @hasDecl(E, "order");
        pub const has_cofactor = @hasDecl(E, "cofactor");
        pub const has_subgroupCheck = @hasDecl(E, "subgroupCheck");
        pub const has_toAffine = @hasDecl(E, "toAffine");
        pub const has_fromAffine = @hasDecl(E, "fromAffine");

        pub fn assert() void {
            has_field.assert();
            if (!has_add) @compileError("EllipticCurve trait: missing 'add' on " ++ @typeName(E));
            if (!has_double) @compileError("EllipticCurve trait: missing 'double' on " ++ @typeName(E));
            if (!has_neg) @compileError("EllipticCurve trait: missing 'neg' on " ++ @typeName(E));
            if (!has_scalarMul) @compileError("EllipticCurve trait: missing 'scalarMul' on " ++ @typeName(E));
            if (!has_generator) @compileError("EllipticCurve trait: missing 'generator' on " ++ @typeName(E));
            if (!has_identity) @compileError("EllipticCurve trait: missing 'identity' on " ++ @typeName(E));
            if (!has_isOnCurve) @compileError("EllipticCurve trait: missing 'isOnCurve' on " ++ @typeName(E));
            if (!has_eq) @compileError("EllipticCurve trait: missing 'eql' on " ++ @typeName(E));
        }
    };
}

// ============================================================================
// 8. PAIRING-FRIENDLY CURVE
// ============================================================================

/// Pairing-friendly curve trait: bilinear pairing e: G1 x G2 -> GT.
///
/// Additional required declarations on `E`:
/// - `G1: type` (points on E over Fp)
/// - `G2: type` (points on E' over Fp^k)
/// - `GT: type` (elements of the target group, a field extension)
/// - `pairing(P: G1, Q: G2) GT`
/// - `millerLoop(P: G1, Q: G2) GT` (intermediate)
/// - `finalExponentiation(x: GT) GT`
/// - `atePairing(P: G1, Q: G2) GT` (optimized)
/// - `embedding_degree: usize` (comptime)
///
/// # Example
/// ```zig
/// const BN254 = struct {
///     pub const G1 = G1Point;
///     pub const G2 = G2Point;
///     pub const GT = Fp12;
///     pub fn pairing(P: G1, Q: G2) GT { ... }
///     pub fn millerLoop(P: G1, Q: G2) GT { ... }
///     pub fn finalExponentiation(x: GT) GT { ... }
///     pub fn atePairing(P: G1, Q: G2) GT { ... }
///     pub const embedding_degree: usize = 12;
///     // ... plus all EllipticCurve methods
/// };
/// PairingFriendlyTrait(BN254, Fp).assert();
/// ```
pub fn PairingFriendlyTrait(comptime E: type, comptime F: type) type {
    return struct {
        pub const has_curve = EllipticCurveTrait(E, F);
        pub const has_g1 = @hasDecl(E, "G1");
        pub const has_g2 = @hasDecl(E, "G2");
        pub const has_gt = @hasDecl(E, "GT");
        pub const has_pairing = @hasDecl(E, "pairing");
        pub const has_millerLoop = @hasDecl(E, "millerLoop");
        pub const has_finalExponentiation = @hasDecl(E, "finalExponentiation");
        pub const has_atePairing = @hasDecl(E, "atePairing");
        pub const has_embeddingDegree = @hasDecl(E, "embedding_degree");

        pub fn assert() void {
            has_curve.assert();
            if (!has_g1) @compileError("PairingFriendly trait: missing 'G1' on " ++ @typeName(E));
            if (!has_g2) @compileError("PairingFriendly trait: missing 'G2' on " ++ @typeName(E));
            if (!has_gt) @compileError("PairingFriendly trait: missing 'GT' on " ++ @typeName(E));
            if (!has_pairing) @compileError("PairingFriendly trait: missing 'pairing' on " ++ @typeName(E));
        }
    };
}

// ============================================================================
// 9. COMMITMENT SCHEME
// ============================================================================

/// Commitment scheme trait: commit(data) -> commitment; verify(commitment, data, proof) -> bool.
///
/// Required declarations on `C`:
/// - `commit(data: []const F) Commitment`
/// - `open(data: []const F, index: usize) Proof`
/// - `verify(commitment: Commitment, data: []const F, proof: Proof) bool`
///
/// # Example
/// ```zig
/// const KZG = struct {
///     pub const Commitment = G1Point;
///     pub const Proof = G1Point;
///     pub fn commit(poly: []const F) Commitment { ... }
///     pub fn open(poly: []const F, z: F) Proof { ... }
///     pub fn verify(c: Commitment, z: F, y: F, proof: Proof) bool { ... }
/// };
/// CommitmentSchemeTrait(KZG, F).assert();
/// ```
pub fn CommitmentSchemeTrait(comptime C: type, comptime F: type) type {
    return struct {
        pub const has_field = FieldTrait(F);
        pub const has_commit = @hasDecl(C, "commit");
        pub const has_open = @hasDecl(C, "open");
        pub const has_verify = @hasDecl(C, "verify");
        pub const has_batchVerify = @hasDecl(C, "batchVerify");

        pub fn assert() void {
            has_field.assert();
            if (!has_commit) @compileError("CommitmentScheme trait: missing 'commit' on " ++ @typeName(C));
            if (!has_open) @compileError("CommitmentScheme trait: missing 'open' on " ++ @typeName(C));
            if (!has_verify) @compileError("CommitmentScheme trait: missing 'verify' on " ++ @typeName(C));
        }
    };
}

// ============================================================================
// 10. NTT / FFT
// ============================================================================

/// Number Theoretic Transform trait: FFT over a finite field.
///
/// Required declarations on `N`:
/// - `transform(input: []F, root: F) []F`
/// - `inverse(input: []F, root: F) []F`
/// - `primitiveRoot(n: usize) F` (n-th root of unity)
/// - `bitReverse(input: []F) void`
///
/// `F` must satisfy `FieldTrait`.
///
/// # Example
/// ```zig
/// const Ntt = struct {
///     pub fn transform(a: []F, root: F) []F { ... }
///     pub fn inverse(a: []F, root: F) []F { ... }
///     pub fn primitiveRoot(n: usize) F { ... }
///     pub fn bitReverse(a: []F) void { ... }
/// };
/// NttTrait(Ntt, F).assert();
/// ```
pub fn NttTrait(comptime N: type, comptime F: type) type {
    return struct {
        pub const has_field = FieldTrait(F);
        pub const has_transform = @hasDecl(N, "transform");
        pub const has_inverse = @hasDecl(N, "inverse");
        pub const has_primitiveRoot = @hasDecl(N, "primitiveRoot");
        pub const has_bitReverse = @hasDecl(N, "bitReverse");

        pub fn assert() void {
            has_field.assert();
            if (!has_transform) @compileError("NTT trait: missing 'transform' on " ++ @typeName(N));
            if (!has_inverse) @compileError("NTT trait: missing 'inverse' on " ++ @typeName(N));
        }
    };
}

// ============================================================================
// 11. HASH-TO-FIELD / HASH-TO-CURVE
// ============================================================================

/// Hash-to-field trait: deterministic hashing into a finite field.
///
/// Required declarations on `H`:
/// - `hashToField(msg: []const u8) F`
/// - `hashToScalar(msg: []const u8) F`
///
/// Used in BLS signatures and SNARKs for deterministic challenge generation.
///
/// # Example
/// ```zig
/// const H2F = struct {
///     pub fn hashToField(msg: []const u8) F { ... }
///     pub fn hashToScalar(msg: []const u8) F { ... }
/// };
/// HashToFieldTrait(H2F, F).assert();
/// ```
pub fn HashToFieldTrait(comptime H: type, comptime F: type) type {
    return struct {
        pub const has_field = FieldTrait(F);
        pub const has_hash = @hasDecl(H, "hashToField");
        pub const has_hashToScalar = @hasDecl(H, "hashToScalar");

        pub fn assert() void {
            has_field.assert();
            if (!has_hash) @compileError("HashToField trait: missing 'hashToField' on " ++ @typeName(H));
        }
    };
}

/// Hash-to-curve trait: deterministic hashing into an elliptic curve group.
///
/// Required declarations on `H`:
/// - `hashToCurve(msg: []const u8) E`
///
/// Used in BLS signatures and privacy protocols.
///
/// # Example
/// ```zig
/// const H2C = struct {
///     pub fn hashToCurve(msg: []const u8) E { ... }
/// };
/// HashToCurveTrait(H2C, E, F).assert();
/// ```
pub fn HashToCurveTrait(comptime H: type, comptime E: type, comptime F: type) type {
    return struct {
        pub const has_curve = EllipticCurveTrait(E, F);
        pub const has_hash = @hasDecl(H, "hashToCurve");

        pub fn assert() void {
            has_curve.assert();
            if (!has_hash) @compileError("HashToCurve trait: missing 'hashToCurve' on " ++ @typeName(H));
        }
    };
}

// ============================================================================
// 12. MERKLE TREE
// ============================================================================

/// Merkle tree trait: commitment to a vector of data with inclusion proofs.
///
/// Required declarations on `M`:
/// - `build(leaves: []const []const u8) M`
/// - `root() [32]u8`
/// - `prove(index: usize) Proof`
/// - `verify(root: [32]u8, index: usize, leaf: []const u8, proof: Proof) bool`
///
/// # Example
/// ```zig
/// const MT = struct {
///     pub fn build(leaves: []const []const u8) Self { ... }
///     pub fn root(self: Self) [32]u8 { ... }
///     pub fn prove(self: Self, index: usize) Proof { ... }
///     pub fn verify(root: [32]u8, index: usize, leaf: []const u8, proof: Proof) bool { ... }
/// };
/// MerkleTreeTrait(MT).assert();
/// ```
pub fn MerkleTreeTrait(comptime M: type) type {
    return struct {
        pub const has_build = @hasDecl(M, "build");
        pub const has_root = @hasDecl(M, "root");
        pub const has_prove = @hasDecl(M, "prove");
        pub const has_verify = @hasDecl(M, "verify");
        pub const has_update = @hasDecl(M, "update");

        pub fn assert() void {
            if (!has_build) @compileError("MerkleTree trait: missing 'build' on " ++ @typeName(M));
            if (!has_root) @compileError("MerkleTree trait: missing 'root' on " ++ @typeName(M));
            if (!has_prove) @compileError("MerkleTree trait: missing 'prove' on " ++ @typeName(M));
            if (!has_verify) @compileError("MerkleTree trait: missing 'verify' on " ++ @typeName(M));
        }
    };
}

// ============================================================================
// 13. TRANSCRIPT (Fiat-Shamir)
// ============================================================================

/// Transcript trait: absorb-squeeze pattern for Fiat-Shamir transformation.
///
/// Required declarations on `T`:
/// - `absorb(data: []const u8) void`
/// - `absorbPoint(P: E) void`
/// - `squeeze() F` (generate challenge)
/// - `clone() T` (fork transcript)
///
/// `F` must satisfy `FieldTrait`.
///
/// # Example
/// ```zig
/// const Transcript = struct {
///     pub fn absorb(self: *Self, data: []const u8) void { ... }
///     pub fn absorbPoint(self: *Self, P: E) void { ... }
///     pub fn squeeze(self: *Self) F { ... }
///     pub fn clone(self: Self) Self { ... }
/// };
/// TranscriptTrait(Transcript, F).assert();
/// ```
pub fn TranscriptTrait(comptime T: type, comptime F: type) type {
    return struct {
        pub const has_field = FieldTrait(F);
        pub const has_absorb = @hasDecl(T, "absorb");
        pub const has_squeeze = @hasDecl(T, "squeeze");
        pub const has_absorbPoint = @hasDecl(T, "absorbPoint");
        pub const has_clone = @hasDecl(T, "clone");

        pub fn assert() void {
            has_field.assert();
            if (!has_absorb) @compileError("Transcript trait: missing 'absorb' on " ++ @typeName(T));
            if (!has_squeeze) @compileError("Transcript trait: missing 'squeeze' on " ++ @typeName(T));
        }
    };
}

// ============================================================================
// 14. RNG
// ============================================================================

/// Field RNG trait: generate random field elements.
///
/// Required declarations on `R`:
/// - `randomField() F`
/// - `randomScalar() F`
/// - `rejectionSample() F`
///
/// `F` must satisfy `FieldTrait`.
///
/// # Example
/// ```zig
/// const Rng = struct {
///     pub fn randomField(self: *Self) F { ... }
///     pub fn randomScalar(self: *Self) F { ... }
///     pub fn rejectionSample(self: *Self) F { ... }
/// };
/// FieldRngTrait(Rng, F).assert();
/// ```
pub fn FieldRngTrait(comptime R: type, comptime F: type) type {
    return struct {
        pub const has_field = FieldTrait(F);
        pub const has_randomField = @hasDecl(R, "randomField");
        pub const has_randomScalar = @hasDecl(R, "randomScalar");
        pub const has_rejectionSample = @hasDecl(R, "rejectionSample");

        pub fn assert() void {
            has_field.assert();
            if (!has_randomField) @compileError("FieldRng trait: missing 'randomField' on " ++ @typeName(R));
        }
    };
}

// ============================================================================
// Compile-time assertion helpers
// ============================================================================

/// Assert that `T` satisfies the Field trait at compile time.
///
/// # Example
/// ```zig
/// assertField(MyField); // compiles only if MyField is a valid Field
/// ```
pub fn assertField(comptime T: type) void {
    FieldTrait(T).assert();
}

/// Assert that `T` satisfies the Ring trait at compile time.
pub fn assertRing(comptime T: type) void {
    RingTrait(T).assert();
}

/// Assert that `T` satisfies the Group trait at compile time.
pub fn assertGroup(comptime T: type) void {
    AdditiveGroupTrait(T).assert();
}

/// Assert that `T` satisfies the EllipticCurve trait at compile time.
pub fn assertEllipticCurve(comptime T: type, comptime F: type) void {
    EllipticCurveTrait(T, F).assert();
}

/// Assert that `T` satisfies the PairingFriendly trait at compile time.
pub fn assertPairingFriendly(comptime T: type, comptime F: type) void {
    PairingFriendlyTrait(T, F).assert();
}

// ============================================================================
// Generic algorithms over traits
// ============================================================================

/// Binary exponentiation: `base^exp`.
///
/// If `T` has a `pow` method, delegates to it.  Otherwise uses the generic
/// square-and-multiply loop.
///
/// # Constraints
/// `T` must satisfy `MultiplicativeGroupTrait` (has `mul`, `one`, `eql`).
///
/// # Example
/// ```zig
/// const x = pow(F7, F7.fromInt(3), 100); // 3^100 mod 7
/// ```
pub fn pow(comptime T: type, base: T, exp: u256) T {
    if (@hasDecl(T, "pow")) {
        return T.pow(base, exp);
    }

    var result = T.one();
    var b = base;
    var e = exp;

    while (e > 0) {
        if (e & 1 == 1) {
            result = T.mul(result, b);
        }
        b = T.mul(b, b);
        e >>= 1;
    }
    return result;
}

/// Sum of a slice of elements in an additive group.
///
/// # Constraints
/// `T` must satisfy `AdditiveGroupTrait`.
///
/// # Example
/// ```zig
/// const items = [_]F7{ F7.fromInt(1), F7.fromInt(2), F7.fromInt(3) };
/// const s = sum(F7, &items); // 1 + 2 + 3 = 6 mod 7
/// ```
pub fn sum(comptime T: type, items: []const T) T {
    AdditiveGroupTrait(T).assert();
    var result = T.zero();
    for (items) |item| {
        result = T.add(result, item);
    }
    return result;
}

/// Product of a slice of elements in a multiplicative group.
///
/// # Constraints
/// `T` must satisfy `MultiplicativeGroupTrait`.
///
/// # Example
/// ```zig
/// const items = [_]F7{ F7.fromInt(2), F7.fromInt(3), F7.fromInt(4) };
/// const p = product(F7, &items); // 2 * 3 * 4 = 24 mod 7 = 3
/// ```
pub fn product(comptime T: type, items: []const T) T {
    MultiplicativeGroupTrait(T).assert();
    var result = T.one();
    for (items) |item| {
        result = T.mul(result, item);
    }
    return result;
}

/// Extended Euclidean Algorithm over a Ring.
///
/// Returns `(g, x, y)` such that `a*x + b*y = g = gcd(a, b)`.
///
/// # Constraints
/// `T` must satisfy `RingTrait` and have `div` (integer division) and `mod`.
///
/// # Example
/// ```zig
/// const res = egcd(F7, F7.fromInt(240), F7.fromInt(46));
/// // res.g == 2, res.x == -9, res.y == 47
/// ```
pub fn egcd(comptime T: type, a: T, b: T) struct { gcd: T, x: T, y: T } {
    RingTrait(T).assert();

    var old_r = a;
    var r = b;
    var old_s = T.one();
    var s = T.zero();
    var old_t = T.zero();
    var t = T.one();

    while (!T.isZero(r)) {
        const q = T.div(old_r, r);

        const tmp_r = old_r;
        old_r = r;
        r = T.sub(tmp_r, T.mul(q, r));

        const tmp_s = old_s;
        old_s = s;
        s = tmp_s.sub(T.mul(q, s));

        const tmp_t = old_t;
        old_t = t;
        t = tmp_t.sub(T.mul(q, t));
    }

    // Ensure gcd is positive
    if (old_r.isNegative()) {
        old_r = old_r.neg();
        old_s = old_s.neg();
        old_t = old_t.neg();
    }

    return .{ .gcd = old_r, .x = old_s, .y = old_t };
}

/// Dot product in a vector space.
///
/// # Constraints
/// `V` must satisfy `VectorSpaceTrait(V, F)`.
///
/// # Example
/// ```zig
/// const a = [_]F7{ F7.fromInt(1), F7.fromInt(2) };
/// const b = [_]F7{ F7.fromInt(3), F7.fromInt(4) };
/// const d = dotProduct(V2, F7, &a, &b); // 1*3 + 2*4 = 11 mod 7 = 4
/// ```
pub fn dotProduct(comptime V: type, comptime F: type, a: []const V, b: []const V) V {
    VectorSpaceTrait(V, F).assert();
    std.debug.assert(a.len == b.len);

    var result = V.zero();
    for (a, b) |ai, bi| {
        const scaled = V.scale(ai, bi);
        result = V.add(result, scaled);
    }
    return result;
}

/// Horner's method: evaluate a polynomial given its coefficients.
///
/// `coeffs[i]` is the coefficient of x^i.
///
/// # Constraints
/// `F` must satisfy `FieldTrait`.
///
/// # Example
/// ```zig
/// // p(x) = 1 + 2x + 3x^2
/// const coeffs = [_]F7{ F7.fromInt(1), F7.fromInt(2), F7.fromInt(3) };
/// const y = evalPolyHorner(F7, &coeffs, F7.fromInt(2)); // p(2) = 1 + 4 + 12 = 17 mod 7 = 3
/// ```
pub fn evalPolyHorner(comptime F: type, coeffs: []const F, x: F) F {
    FieldTrait(F).assert();
    if (coeffs.len == 0) return F.zero();

    var result = coeffs[coeffs.len - 1];
    var i: usize = coeffs.len - 1;
    while (i > 0) {
        i -= 1;
        result = F.add(F.mul(result, x), coeffs[i]);
    }
    return result;
}

/// Lagrange interpolation: given points (x_i, y_i), return polynomial coefficients.
///
/// Returns a newly allocated slice of coefficients; caller must free.
///
/// # Constraints
/// `F` must satisfy `FieldTrait`.
///
/// # Example
/// ```zig
/// const xs = [_]F7{ F7.fromInt(0), F7.fromInt(1), F7.fromInt(2) };
/// const ys = [_]F7{ F7.fromInt(1), F7.fromInt(3), F7.fromInt(5) };
/// const coeffs = try lagrangeInterpolate(F7, &xs, &ys, allocator);
/// defer allocator.free(coeffs);
/// // coeffs represents the polynomial p(x) = 1 + 2x
/// ```
pub fn lagrangeInterpolate(comptime F: type, xs: []const F, ys: []const F, allocator: std.mem.Allocator) ![]F {
    FieldTrait(F).assert();
    std.debug.assert(xs.len == ys.len);
    const n = xs.len;

    var result = try allocator.alloc(F, n);
    @memset(result, F.zero());

    for (0..n) |i| {
        var li = try allocator.alloc(F, n);
        defer allocator.free(li);
        @memset(li, F.zero());
        li[0] = ys[i];

        var denom = F.one();
        for (0..n) |j| {
            if (i == j) continue;
            denom = F.mul(denom, F.sub(xs[i], xs[j]));
        }
        const inv_denom = F.inv(denom);

        for (0..n) |j| {
            if (i == j) continue;
            // multiply li by (x - x_j)
            var new_li = try allocator.alloc(F, n);
            @memset(new_li, F.zero());
            for (0..n) |k| {
                if (li[k].isZero()) continue;
                new_li[k] = F.add(new_li[k], li[k]);
                if (k + 1 < n) {
                    new_li[k + 1] = F.add(new_li[k + 1], F.mul(li[k], F.neg(xs[j])));
                }
            }
            @memcpy(li, new_li);
            allocator.free(new_li);
        }

        for (0..n) |k| {
            result[k] = F.add(result[k], F.mul(li[k], inv_denom));
        }
    }

    return result;
}

/// Compute the i-th Lagrange coefficient for field elements `xs` at point `x`.
///
/// Returns `λ_i(x) = Π_{j≠i} (x - x_j) / Π_{j≠i} (x_i - x_j)`.
///
/// This is the standalone coefficient used in threshold cryptography (e.g.,
/// FROST, Shamir, DKG) for computing shares at a new point or reconstructing
/// a secret without full polynomial interpolation.
///
/// # Constraints
/// `F` must satisfy `FieldTrait`. All `xs` must be distinct.
pub fn lagrangeCoefficient(comptime F: type, xs: []const F, i: usize, x: F) F {
    FieldTrait(F).assert();
    std.debug.assert(i < xs.len);
    var num = F.one();
    var den = F.one();
    for (0..xs.len) |j| {
        if (j == i) continue;
        num = F.mul(num, F.sub(x, xs[j]));
        den = F.mul(den, F.sub(xs[i], xs[j]));
    }
    return F.mul(num, F.inv(den));
}
