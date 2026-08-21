//! zig-algebra-traits
//!
//! Contratos de tipo (traits) para álgebra computacional en Zig.
//! Fundamento del ecosistema zig-algebra-core.

pub const traits = @import("traits.zig");

// Re-export all trait functions for convenience
pub const AlgebraError = traits.AlgebraError;
pub const SetTrait = traits.SetTrait;
pub const GroupTrait = traits.GroupTrait;
pub const AdditiveGroupTrait = traits.AdditiveGroupTrait;
pub const MultiplicativeGroupTrait = traits.MultiplicativeGroupTrait;
pub const RingTrait = traits.RingTrait;
pub const FieldTrait = traits.FieldTrait;
pub const PrimeFieldTrait = traits.PrimeFieldTrait;
pub const FieldExtensionTrait = traits.FieldExtensionTrait;
pub const VectorSpaceTrait = traits.VectorSpaceTrait;
pub const PolynomialRingTrait = traits.PolynomialRingTrait;
pub const EllipticCurveTrait = traits.EllipticCurveTrait;
pub const PairingFriendlyTrait = traits.PairingFriendlyTrait;
pub const CommitmentSchemeTrait = traits.CommitmentSchemeTrait;
pub const NttTrait = traits.NttTrait;
pub const HashToFieldTrait = traits.HashToFieldTrait;
pub const HashToCurveTrait = traits.HashToCurveTrait;
pub const MerkleTreeTrait = traits.MerkleTreeTrait;
pub const TranscriptTrait = traits.TranscriptTrait;
pub const FieldRngTrait = traits.FieldRngTrait;

// Re-export assertion helpers
pub const assertField = traits.assertField;
pub const assertRing = traits.assertRing;
pub const assertGroup = traits.assertGroup;
pub const assertEllipticCurve = traits.assertEllipticCurve;
pub const assertPairingFriendly = traits.assertPairingFriendly;

// Re-export generic algorithms
pub const pow = traits.pow;
pub const sum = traits.sum;
pub const product = traits.product;
pub const egcd = traits.egcd;
pub const dotProduct = traits.dotProduct;
pub const evalPolyHorner = traits.evalPolyHorner;
pub const lagrangeInterpolate = traits.lagrangeInterpolate;
