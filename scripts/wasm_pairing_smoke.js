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

  const expected = [
    8493334370784016972005089913588211327688223499729897951716206968320726508021n,
    3758435817766288188804561253838670030762970764366672594784247447067868088068n,
    6565798094314091391201231504228224566495939541538094766881371862976727043038n,
    14656606573936501743457633041048024656612227301473084805627390748872617280984n,
    634997487638609332803583491743335852620873788902390365055086820718589720118n,
    19455424343576886430889849773367397946457449073528455097210946839000147698372n,
    20049218015652006197026173611347504489508678646783216776320737476707192559881n,
    18059168546148152671857026372711724379319778306792011146784665080987064164612n,
    12145052038566888241256672223106590273978429515702193755778990643425246950730n,
    17918828665069491344039743589118342552553375221610735811112289083834142789347n,
    6223602427219597392892794664899549544171383137467762280768257680446283161705n,
    7484542354754424633621663080190936924481536615300815203692506276894207018007n,
  ];
  for (let i = 0; i < expected.length; i++) w32(tmp + i * 32, expected[i]);
  for (let i = 0; i < 384; i++)
    if (mem[out + i] !== mem[tmp + i]) throw new Error("EIP-197 KAT mismatch at byte " + i);
  if (mem[out + 383] === 0) throw new Error("high word missing");

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
