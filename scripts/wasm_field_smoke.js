const fs = require("fs");

(async () => {
  const { instance } = await WebAssembly.instantiate(
    fs.readFileSync("zig-out/bin/zig_algebra_fp.wasm"), {});
  const e = instance.exports;
  for (const name of ["fp_add", "fp_mul", "fp_inv"]) {
    if (typeof e[name] !== "function") throw new Error("missing export: " + name);
  }
  if (!(e.memory instanceof WebAssembly.Memory)) throw new Error("missing memory export");

  const mem = new Uint8Array(e.memory.buffer);
  const out = 1024;
  if (out + 48 > mem.length) throw new Error("insufficient wasm memory");

  const read = (ptr, len) => {
    let value = 0n;
    for (let i = len - 1; i >= 0; i--) value = (value << 8n) | BigInt(mem[ptr + i]);
    return value;
  };
  const expect = (name, actual, expected) => {
    if (actual !== expected) throw new Error(name + " != " + expected);
  };
  const add = (a_lo, a_hi, b_lo, b_hi) => {
    e.fp_add(a_lo, a_hi, b_lo, b_hi, out);
    return read(out, 48);
  };
  const mul = (a_lo, a_hi, b_lo, b_hi) => {
    e.fp_mul(a_lo, a_hi, b_lo, b_hi, out);
    return read(out, 48);
  };

  const M = (1n << 64n) - 1n;
  expect("fp_add(5,7)", add(5n, 0n, 7n, 0n), 12n);
  expect("fp_mul(5,7)", mul(5n, 0n, 7n, 0n), 35n);
  expect("fp_add carry", add(M, 0n, 2n, 0n), M + 2n);
  expect("fp_add hi words", add(0n, 5n, 0n, 7n), 12n << 64n);

  const P = 0x1a0111ea397fe69a4b1ba7b6434bacd764774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaabn;
  let inv = 1n;
  let base = 2n;
  let exponent = P - 2n;
  while (exponent > 0n) {
    if (exponent & 1n) inv = inv * base % P;
    base = base * base % P;
    exponent >>= 1n;
  }
  if (e.fp_inv(2n, 0n, out) !== 1) throw new Error("fp_inv(2) failed");
  expect("fp_inv(2)", read(out, 48), inv);
  if (e.fp_inv(0n, 0n, out) !== 0) throw new Error("fp_inv(0) accepted zero");

  console.log("field wasm OK:", Object.keys(e).join(", "));
})().catch((err) => { console.error(err); process.exit(1); });
