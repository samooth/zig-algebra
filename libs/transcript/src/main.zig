//! zig-transcript consumer: Fiat-Shamir over a field, and the property that
//! makes it worth using at all.
//!
//! A transcript's job is that two parties who absorb the same public values in
//! the same order derive the same challenges, and that any change to any value
//! changes every challenge that follows. The second half is what a
//! "deterministic hash" alone does not give you, and it is what this exercises:
//! flip one absorbed byte and the challenge moves.
//!
//! Range is checked too. `challengeField` decodes through `F.fromBytes`, whose
//! behaviour on an out-of-range input is per-field convention: `zig-field`
//! rejects. The challenge is therefore always a canonical element, which matters
//! because a non-canonical challenge is a different field element than it looks.

const std = @import("std");
const transcript = @import("zig-transcript");
const zf = @import("zig-field");

const Goldilocks = zf.Goldilocks;

pub fn main() !void {
    var t = transcript.Transcript.init("example:transcript");
    t.absorbU64(42);
    t.absorbField(Goldilocks, Goldilocks.fromInt(1337));
    t.absorbBytes("the statement being proved");

    var c1: [32]u8 = undefined;
    t.challengeBytes(&c1);
    std.debug.print("zig-transcript: domain \"example:transcript\"\n\n", .{});
    std.debug.print("  challenge 1: ", .{});
    printHex(&c1);

    // Same values, same order, fresh transcript: must be the same challenge. If
    // this fails the transcript is not reproducible from the statement alone.
    var t_same = transcript.Transcript.init("example:transcript");
    t_same.absorbU64(42);
    t_same.absorbField(Goldilocks, Goldilocks.fromInt(1337));
    t_same.absorbBytes("the statement being proved");
    var c1_again: [32]u8 = undefined;
    t_same.challengeBytes(&c1_again);
    std.debug.print("  reproducible: {s}\n", .{if (std.mem.eql(u8, &c1, &c1_again)) "yes" else "NO"});

    // One bit different, and every challenge after it must move.
    var t2 = transcript.Transcript.init("example:transcript");
    t2.absorbU64(43); // was 42
    t2.absorbField(Goldilocks, Goldilocks.fromInt(1337));
    t2.absorbBytes("the statement being proved");
    var c2: [32]u8 = undefined;
    t2.challengeBytes(&c2);
    std.debug.print("  one absorbed value changed: {s}\n", .{
        if (!std.mem.eql(u8, &c1, &c2)) "challenge moved" else "UNCHANGED",
    });

    // Domain separation: a different label is a different protocol.
    var t3 = transcript.Transcript.init("example:other");
    t3.absorbU64(42);
    t3.absorbField(Goldilocks, Goldilocks.fromInt(1337));
    t3.absorbBytes("the statement being proved");
    var c3: [32]u8 = undefined;
    t3.challengeBytes(&c3);
    std.debug.print("  different domain label:  {s}\n", .{
        if (!std.mem.eql(u8, &c1, &c3)) "challenge moved" else "UNCHANGED",
    });

    // A field challenge is in range, which is the property that makes it usable
    // as an exponent or a fold coefficient.
    var t4 = transcript.Transcript.init("example:transcript");
    t4.absorbBytes("field challenges");
    var in_range = true;
    for (0..64) |_| {
        const f = t4.challengeField(Goldilocks);
        // Canonical means the bytes round-trip: `fromBytes` rejects a value at
        // or above the modulus, so a challenge whose own bytes it will not
        // accept is not a member of the field it claims to come from.
        if (Goldilocks.fromBytes(&f.toBytes())) |back| {
            if (!back.eql(f)) in_range = false;
        } else |_| in_range = false;
    }
    std.debug.print("  64 field challenges all canonical: {s}\n", .{if (in_range) "yes" else "NO"});

    // Sequential challenges differ, which is what stops a prover reusing one.
    var t5 = transcript.Transcript.init("example:transcript");
    t5.absorbU64(1);
    const a = t5.challengeU64();
    const b = t5.challengeU64();
    std.debug.print("  sequential challenges differ:  {s}\n", .{if (a != b) "yes" else "NO"});
}

fn printHex(b: []const u8) void {
    for (b) |byte| std.debug.print("{x:0>2}", .{byte});
    std.debug.print("\n", .{});
}
