const fs = require("fs");
(async () => {
  const { instance } = await WebAssembly.instantiate(
    fs.readFileSync("zig-out/bin/zig_algebra_pairing.wasm"), {});
  const e = instance.exports;
  const mem = new Uint8Array(e.memory.buffer);

  if (e.pairing_api_version() !== 1) throw new Error("api version");

  // G2 generator (EIP-197 / alt_bn128), Fp2 LE limbs
  const P = 21888242871839275222246405745257275088696311157297823662689037894645226208583n;
  const w32 = (ptr, v) => {
    for (let i = 0; i < 32; i++) { mem[ptr + i] = Number(v & 0xFFn); v >>= 8n; }
    if (v !== 0n) throw new Error("overflow >256bit");
  };
  const fp2 = (ptr, c0, c1) => { w32(ptr, c0); w32(ptr + 32, c1); };

  const g1 = e.scratch_ptr();
  const g2 = g1 + 64, out = g2 + 128, out2 = out + 384, tmp = out2 + 384;

  // canonical G1 generator (1, 2)
  w32(g1, 1n); w32(g1 + 32, 2n);
  // canonical G2 generator
  const gx0 = 10857046999023057135944570762232829481370756359578518086990519993285655852781n;
  const gx1 = 11559732032986387107991004021392285783925812861821192530917403151452391805634n;
  const gy0 = 8495653923123431417604973247489272438418190587263600148770280649306958101930n;
  const gy1 = 4082367875863433681332203403145435568316851327593401208105741076214120093531n;
  fp2(g2, gx0, gx1); fp2(g2 + 64, gy0, gy1);

  if (e.g1_validate(g1) !== 1) throw new Error("g1 invalid");
  if (e.g2_validate(g2) !== 1) throw new Error("g2 invalid");

  // invalid point rejected
  w32(g1, 5n); w32(g1 + 32, 999n);
  if (e.g1_validate(g1) !== 0) throw new Error("invalid g1 accepted");
  w32(g1, 1n); w32(g1 + 32, 2n);

  // e(G1, G2) compute twice -> deterministic
  if (e.pairing_compute(out, g1, g2) !== 0) throw new Error("pairing failed");
  if (e.pairing_compute(out2, g1, g2) !== 0) throw new Error("pairing failed");
  for (let i = 0; i < 384; i++)
    if (mem[out + i] !== mem[out2 + i]) throw new Error("non-deterministic");

  // non-degenerate: not all-zero output
  let nz = 0; for (let i = 0; i < 384; i++) nz += mem[out + i] !== 0 ? 1 : 0;
  if (nz < 300) throw new Error("suspiciously sparse output: " + nz);

  // bilinear self-check inside module: e(2G1,3G2) == e(G1,G2)^6
  if (e.pairing_bilinear_check(g1, g2, g1, g2) !== 1)
    throw new Error("bilinear check failed");
  console.log("bilinear check: OK");
  console.log("pairing wasm OK | api:", e.pairing_api_version(),
    "| nonzero bytes:", nz + "/384",
    "| first bytes:", Array.from(mem.slice(out, out + 8)).map(b => b.toString(16).padStart(2, "0")).join(""));
})().catch(err => { console.error("FAIL:", err.message || err); process.exit(1); });
