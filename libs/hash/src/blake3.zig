//! Blake3 hash function (RFC-like implementation).
//!
//! Supports:
//! - Simple one-shot hashing
//! - Extendable-output (XOF) via `finalizeInto`
//! - Keyed hashing and key derivation (derive_key)

const std = @import("std");

pub const BLOCK_LEN = 64;
pub const CHUNK_LEN = 1024;
pub const OUT_LEN = 32;
pub const KEY_LEN = 32;

const IV = [8]u32{
    0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
    0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
};

const MSG_PERMUTATION = [16]u8{ 2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8 };

inline fn g(state: *[16]u32, a: usize, b: usize, c: usize, d: usize, mx: u32, my: u32) void {
    state[a] = state[a] +% state[b] +% mx;
    state[d] = std.math.rotr(u32, state[d] ^ state[a], 16);
    state[c] = state[c] +% state[d];
    state[b] = std.math.rotr(u32, state[b] ^ state[c], 12);
    state[a] = state[a] +% state[b] +% my;
    state[d] = std.math.rotr(u32, state[d] ^ state[a], 8);
    state[c] = state[c] +% state[d];
    state[b] = std.math.rotr(u32, state[b] ^ state[c], 7);
}

inline fn round(state: *[16]u32, m: *const [16]u32) void {
    g(state, 0, 4, 8, 12, m[0], m[1]);
    g(state, 1, 5, 9, 13, m[2], m[3]);
    g(state, 2, 6, 10, 14, m[4], m[5]);
    g(state, 3, 7, 11, 15, m[6], m[7]);
    g(state, 0, 5, 10, 15, m[8], m[9]);
    g(state, 1, 6, 11, 12, m[10], m[11]);
    g(state, 2, 7, 8, 13, m[12], m[13]);
    g(state, 3, 4, 9, 14, m[14], m[15]);
}

inline fn permute(m: *[16]u32) void {
    const orig = m.*;
    for (0..16) |i| {
        m[i] = orig[MSG_PERMUTATION[i]];
    }
}

fn compress(
    chaining_value: *const [8]u32,
    block_words: *const [16]u32,
    counter: u64,
    block_len: u32,
    flags: u32,
) [16]u32 {
    var state: [16]u32 = undefined;
    @memcpy(state[0..8], chaining_value);
    @memcpy(state[8..16], &IV);
    state[12] = @truncate(counter);
    state[13] = @truncate(counter >> 32);
    state[14] = block_len;
    state[15] = flags;

    var m = block_words.*;
    round(&state, &m);
    permute(&m);
    round(&state, &m);
    permute(&m);
    round(&state, &m);
    permute(&m);
    round(&state, &m);
    permute(&m);
    round(&state, &m);
    permute(&m);
    round(&state, &m);
    permute(&m);
    round(&state, &m);

    for (0..8) |i| {
        state[i] ^= state[i + 8];
        state[i + 8] ^= chaining_value[i];
    }
    return state;
}

fn wordsFromLittleEndianBytes(bytes: *const [BLOCK_LEN]u8) [16]u32 {
    var words: [16]u32 = undefined;
    for (0..16) |i| {
        words[i] = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
    }
    return words;
}

/// The inputs to a chunk's or a parent node's final compression, captured
/// *before* the choice between "produce a chaining value" and "produce root
/// output bytes". This is the reference implementation's `Output`, and having
/// it is the whole fix.
///
/// The previous code compressed the chunk's last block eagerly, threw away the
/// inputs, and then re-compressed the *result* with a zero message block and
/// `block_len = BLOCK_LEN` in order to produce the output. Two different
/// computations, so every digest was a self-consistent non-BLAKE3 value: the
/// tree was BLAKE3, the finalisation was not. `verify` style tests cannot see
/// that, which is why it survived since the monorepo's first commit.
const Output = struct {
    input_cv: [8]u32,
    block: [16]u32,
    counter: u64,
    block_len: u32,
    flags: u32,

    /// This node as a chaining value, for feeding a parent or the next chunk.
    fn chainingValue(self: Output) [8]u32 {
        return compress(&self.input_cv, &self.block, self.counter, self.block_len, self.flags)[0..8].*;
    }
};

/// Root output bytes, and the XOF extension: one compression per 64 bytes, with
/// `output_block_counter` in the counter and the ROOT flag added here and only
/// here. A node is ROOT if and only if it is the one being read out.
fn outputRootBytes(in: Output, out: []u8) void {
    var output_block_counter: u64 = 0;
    var out_off: usize = 0;
    while (out_off < out.len) : (output_block_counter += 1) {
        const words = compress(
            &in.input_cv,
            &in.block,
            output_block_counter,
            in.block_len,
            in.flags | ROOT,
        );
        const to_write = @min(BLOCK_LEN, out.len - out_off);
        for (0..to_write / 4) |j| {
            std.mem.writeInt(u32, out[out_off..][0..4], words[j], .little);
            out_off += 4;
        }
        const rem = to_write % 4;
        for (0..rem) |j| {
            out[out_off] = @truncate(words[to_write / 4] >> (@as(u5, @intCast(j)) * 8));
            out_off += 1;
        }
    }
}

// Flags
const CHUNK_START: u32 = 1 << 0;
const CHUNK_END: u32 = 1 << 1;
const PARENT: u32 = 1 << 2;
const ROOT: u32 = 1 << 3;
const KEYED_HASH: u32 = 1 << 4;
const DERIVE_KEY_CONTEXT: u32 = 1 << 5;
const DERIVE_KEY_MATERIAL: u32 = 1 << 6;

/// Blake3 hasher state.
pub const Blake3 = struct {
    key: [8]u32,
    chunk_state: ChunkState,
    cv_stack: [54][8]u32, // max tree depth for 2^64 bytes
    cv_stack_len: u8,
    flags: u32,

    const ChunkState = struct {
        chaining_value: [8]u32,
        chunk_counter: u64,
        buf: [BLOCK_LEN]u8,
        buf_len: u8,
        blocks_compressed: u8,
        flags: u32,

        fn len(self: ChunkState) u64 {
            return @as(u64, self.blocks_compressed) * BLOCK_LEN + self.buf_len;
        }

        fn startFlag(self: ChunkState) u32 {
            if (self.blocks_compressed == 0) return CHUNK_START else return 0;
        }

        fn update(self: *ChunkState, input: []const u8) void {
            var in = input;
            while (in.len > 0) {
                if (self.buf_len == BLOCK_LEN) {
                    const block_words = wordsFromLittleEndianBytes(&self.buf);
                    self.chaining_value = compress(&self.chaining_value, &block_words, self.chunk_counter, BLOCK_LEN, self.startFlag() | self.flags)[0..8].*;
                    self.blocks_compressed += 1;
                    // Zeroed, and not merely advanced: `output` reads all 64
                    // bytes, so a stale tail from a previous block would be
                    // folded into the last block. The buffer is `undefined` at
                    // construction, so the tail is not zero by luck either.
                    @memset(&self.buf, 0);
                    self.buf_len = 0;
                }
                const want = BLOCK_LEN - self.buf_len;
                const take = @min(want, in.len);
                @memcpy(self.buf[self.buf_len .. self.buf_len + take], in[0..take]);
                self.buf_len += @intCast(take);
                in = in[take..];
            }
        }

        /// The chunk's final block as an `Output`. Note the chaining value here
        /// is the one *before* that block is compressed, which is what makes a
        /// single later compression able to serve as both the chaining value and
        /// the root output.
        fn output(self: ChunkState) Output {
            return .{
                .input_cv = self.chaining_value,
                .block = wordsFromLittleEndianBytes(&self.buf),
                .counter = self.chunk_counter,
                .block_len = self.buf_len,
                .flags = self.startFlag() | CHUNK_END | self.flags,
            };
        }
    };

    pub fn init() Blake3 {
        return initInternal(&IV, 0);
    }

    pub fn initKeyed(key: *const [KEY_LEN]u8) Blake3 {
        var key_words: [8]u32 = undefined;
        for (0..8) |i| {
            key_words[i] = std.mem.readInt(u32, key[i * 4 ..][0..4], .little);
        }
        return initInternal(&key_words, KEYED_HASH);
    }

    pub fn initDeriveKey(context: []const u8) Blake3 {
        var context_hasher = initInternal(&IV, DERIVE_KEY_CONTEXT);
        context_hasher.update(context);
        var context_key: [KEY_LEN]u8 = undefined;
        context_hasher.finalize(&context_key);
        var key_words: [8]u32 = undefined;
        for (0..8) |i| {
            key_words[i] = std.mem.readInt(u32, context_key[i * 4 ..][0..4], .little);
        }
        return initInternal(&key_words, DERIVE_KEY_MATERIAL);
    }

    fn initInternal(key_words: *const [8]u32, flags: u32) Blake3 {
        var cv_stack: [54][8]u32 = undefined;
        for (&cv_stack) |*c| {
            c.* = [_]u32{0} ** 8;
        }
        return .{
            .key = key_words.*,
            .chunk_state = .{
                .chaining_value = key_words.*,
                .chunk_counter = 0,
                .buf = [_]u8{0} ** BLOCK_LEN,
                .buf_len = 0,
                .blocks_compressed = 0,
                .flags = flags,
            },
            .cv_stack = cv_stack,
            .cv_stack_len = 0,
            .flags = flags,
        };
    }

    fn pushCv(self: *Blake3, cv: *const [8]u32) void {
        self.cv_stack[self.cv_stack_len] = cv.*;
        self.cv_stack_len += 1;
    }

    fn popCv(self: *Blake3) [8]u32 {
        self.cv_stack_len -= 1;
        return self.cv_stack[self.cv_stack_len];
    }

    /// A parent node over two child chaining values. `PARENT` nodes always use
    /// counter 0 and `block_len = BLOCK_LEN`, and they are never ROOT here --
    /// ROOT is decided once, by `outputRootBytes`, for the single node that is
    /// actually read out.
    fn parentOutput(left_child: [8]u32, right_child: [8]u32, key: [8]u32, flags: u32) Output {
        var block: [16]u32 = undefined;
        @memcpy(block[0..8], &left_child);
        @memcpy(block[8..16], &right_child);
        return .{
            .input_cv = key,
            .block = block,
            .counter = 0,
            .block_len = BLOCK_LEN,
            .flags = PARENT | flags,
        };
    }

    fn addChunkChainingValue(self: *Blake3, new_cv_in: [8]u32, total_chunks: u64) void {
        var new_cv = new_cv_in;
        var new_total_chunks = total_chunks;
        while (new_total_chunks & 1 == 0) {
            const left_child = self.popCv();
            new_cv = parentOutput(left_child, new_cv, self.key, self.flags).chainingValue();
            new_total_chunks >>= 1;
        }
        self.pushCv(&new_cv);
    }

    pub fn update(self: *Blake3, input: []const u8) void {
        var in = input;
        while (in.len > 0) {
            if (self.chunk_state.len() == CHUNK_LEN) {
                // This chunk is complete and more input is coming, so it is not
                // the root: it contributes a chaining value to the tree.
                const chunk_cv = self.chunk_state.output().chainingValue();
                const total_chunks = self.chunk_state.chunk_counter + 1;
                self.addChunkChainingValue(chunk_cv, total_chunks);
                self.chunk_state = .{
                    .chaining_value = self.key,
                    .chunk_counter = total_chunks,
                    .buf = [_]u8{0} ** BLOCK_LEN,
                    .buf_len = 0,
                    .blocks_compressed = 0,
                    .flags = self.flags,
                };
            }
            const want = CHUNK_LEN - self.chunk_state.len();
            const take = @min(want, in.len);
            self.chunk_state.update(in[0..take]);
            in = in[take..];
        }
    }

    pub fn finalize(self: *Blake3, out: *[OUT_LEN]u8) void {
        self.finalizeInto(out);
    }

    pub fn finalizeInto(self: *Blake3, out: []u8) void {
        // Walk the right edge of the tree, building the root's *inputs*. No
        // compression happens here: `outputRootBytes` does exactly one, with
        // the ROOT flag. Compressing in the loop and then compressing the
        // result again is what made this not BLAKE3.
        var output = self.chunk_state.output();
        var parent_nodes_remaining: usize = self.cv_stack_len;
        while (parent_nodes_remaining > 0) {
            parent_nodes_remaining -= 1;
            const parent_cv = self.cv_stack[parent_nodes_remaining];
            output = parentOutput(parent_cv, output.chainingValue(), self.key, self.flags);
        }
        outputRootBytes(output, out);
    }

    /// One-shot hash as a static method (for compatibility with MerkleTree).
    pub fn hashBytes(input: []const u8) [OUT_LEN]u8 {
        return hash(input);
    }
};

/// One-shot hash.
pub fn hash(input: []const u8) [OUT_LEN]u8 {
    var hasher = Blake3.init();
    hasher.update(input);
    var out: [OUT_LEN]u8 = undefined;
    hasher.finalize(&out);
    return out;
}

/// One-shot keyed hash.
pub fn keyedHash(key: *const [KEY_LEN]u8, input: []const u8) [OUT_LEN]u8 {
    var hasher = Blake3.initKeyed(key);
    hasher.update(input);
    var out: [OUT_LEN]u8 = undefined;
    hasher.finalize(&out);
    return out;
}

/// One-shot derive key.
pub fn deriveKey(context: []const u8, material: []const u8) [OUT_LEN]u8 {
    var hasher = Blake3.initDeriveKey(context);
    hasher.update(material);
    var out: [OUT_LEN]u8 = undefined;
    hasher.finalize(&out);
    return out;
}
