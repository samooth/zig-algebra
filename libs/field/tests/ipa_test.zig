const std = @import("std");
const zf = @import("zig-field");

const Ipa = zf.Ipa(zf.M31);

fn setup() !Ipa {
    return Ipa.init(std.testing.allocator, 4, [_]u8{1} ** 32);
}

test "IPA basic prove and verify" {
    var ipa = try setup();
    defer ipa.deinit();

    const a = [_]zf.M31{ zf.M31.fromInt(1), zf.M31.fromInt(2), zf.M31.fromInt(3), zf.M31.fromInt(4) };
    const b = [_]zf.M31{ zf.M31.fromInt(5), zf.M31.fromInt(6), zf.M31.fromInt(7), zf.M31.fromInt(8) };
    const c = Ipa.innerProduct(&a, &b);
    const commitment = ipa.commit(&a, &b, c);
    var proof = try ipa.prove(std.testing.allocator, &a, &b);
    defer proof.deinit(std.testing.allocator);

    try ipa.verifyWithCommitment(commitment, &proof);
}

test "IPA verify fails with wrong commitment" {
    var ipa = try setup();
    defer ipa.deinit();

    const a = [_]zf.M31{ zf.M31.fromInt(1), zf.M31.fromInt(2), zf.M31.fromInt(3), zf.M31.fromInt(4) };
    const b = [_]zf.M31{ zf.M31.fromInt(5), zf.M31.fromInt(6), zf.M31.fromInt(7), zf.M31.fromInt(8) };
    const c = Ipa.innerProduct(&a, &b);
    const commitment = ipa.commit(&a, &b, c);
    var proof = try ipa.prove(std.testing.allocator, &a, &b);
    defer proof.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.VerificationFailed,
        ipa.verifyWithCommitment(commitment.add(zf.M31.one()), &proof),
    );
}
