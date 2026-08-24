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

fn outputChainingValue(out: *[OUT_LEN]u8, compressed: *const [16]u32) void {
    for (0..8) |i| {
        std.mem.writeInt(u32, out[i * 4 ..][0..4], compressed[i], .little);
    }
}

fn outputRootBytes(compressed: *const [16]u32, out: []u8) void {
    var output_block_counter: u64 = 0;
    var out_off: usize = 0;
    while (out_off < out.len) : (output_block_counter += 1) {
        var words: [16]u32 = undefined;
        @memcpy(words[0..8], compressed[0..8]);
        @memcpy(words[8..16], &IV);
        words[12] = @truncate(output_block_counter);
        words[13] = @truncate(output_block_counter >> 32);
        words[14] = BLOCK_LEN;
        words[15] = ROOT;

        var m = [_]u32{0} ** 16;
        round(&words, &m);
        permute(&m);
        round(&words, &m);
        permute(&m);
        round(&words, &m);
        permute(&m);
        round(&words, &m);
        permute(&m);
        round(&words, &m);
        permute(&m);
        round(&words, &m);
        permute(&m);
        round(&words, &m);

        for (0..8) |i| {
            words[i] ^= words[i + 8];
        }

        const to_write = @min(32, out.len - out_off);
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
                    self.buf_len = 0;
                    if (self.blocks_compressed == CHUNK_LEN / BLOCK_LEN) {
                        return; // chunk full, caller must handle
                    }
                }
                const want = BLOCK_LEN - self.buf_len;
                const take = @min(want, in.len);
                @memcpy(self.buf[self.buf_len .. self.buf_len + take], in[0..take]);
                self.buf_len += @intCast(take);
                in = in[take..];
            }
        }

        fn output(self: ChunkState) [16]u32 {
            const block_words = wordsFromLittleEndianBytes(&self.buf);
            const block_len = self.buf_len;
            const flags = self.startFlag() | CHUNK_END | self.flags;
            return compress(&self.chaining_value, &block_words, self.chunk_counter, block_len, flags);
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
        return .{
            .key = key_words.*,
            .chunk_state = .{
                .chaining_value = key_words.*,
                .chunk_counter = 0,
                .buf = undefined,
                .buf_len = 0,
                .blocks_compressed = 0,
                .flags = flags,
            },
            .cv_stack = undefined,
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

    fn addChunkChainingValue(self: *Blake3, new_cv: *[8]u32, total_chunks: u64) void {
        var new_total_chunks = total_chunks;
        while (new_total_chunks & 1 == 0) {
            const left_child = self.popCv();
            var block_words: [16]u32 = undefined;
            @memcpy(block_words[0..8], &left_child);
            @memcpy(block_words[8..16], new_cv);
            const parent = compress(&self.key, &block_words, 0, BLOCK_LEN, PARENT | self.flags);
            new_cv.* = parent[0..8].*;
            new_total_chunks >>= 1;
        }
        self.pushCv(new_cv);
    }

    pub fn update(self: *Blake3, input: []const u8) void {
        var in = input;
        while (in.len > 0) {
            if (self.chunk_state.len() == CHUNK_LEN) {
                var chunk_cv = self.chunk_state.output()[0..8].*;
                const total_chunks = self.chunk_state.chunk_counter + 1;
                self.addChunkChainingValue(&chunk_cv, total_chunks);
                self.chunk_state = .{
                    .chaining_value = self.key,
                    .chunk_counter = total_chunks,
                    .buf = undefined,
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
        var output = self.chunk_state.output();
        var parent_nodes_remaining: usize = self.cv_stack_len;
        while (parent_nodes_remaining > 0) {
            parent_nodes_remaining -= 1;
            const parent_cv = self.cv_stack[parent_nodes_remaining];
            var block_words: [16]u32 = undefined;
            @memcpy(block_words[0..8], &parent_cv);
            @memcpy(block_words[8..16], output[0..8]);
            if (parent_nodes_remaining == 0) {
                output = compress(&self.key, &block_words, 0, BLOCK_LEN, PARENT | ROOT | self.flags);
            } else {
                output = compress(&self.key, &block_words, 0, BLOCK_LEN, PARENT | self.flags);
            }
        }
        outputRootBytes(&output, out);
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
