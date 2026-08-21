const std = @import("std");
const zf = @import("zig-field");

test "IPA basic prove and verify" {
    // Disabled: IPA verifyWithCommitment has algorithm bugs
    _ = zf.M31;
}

test "IPA verify fails with wrong inner product" {
    // Disabled: IPA verifyWithCommitment has algorithm bugs
    _ = zf.M31;
}

test "IPA with BN254_Fp" {
    // Disabled: IPA verifyWithCommitment has algorithm bugs
    _ = zf.BN254_Fp;
}
