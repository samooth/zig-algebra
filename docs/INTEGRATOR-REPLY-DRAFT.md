# Borrador de respuesta a la revisión externa — NO ENVIAR sin revisión

Estado: `draft`. Los tres puntos de abajo son **correcciones a la descripción
de la API que la revisión da por sentado**, y repetirlas sin corregir serían
peores que no responder: consolidarían una API que no existe.

---

## 1. P1-3: la superficie de la API no es irregular, es uniformemente fija

La revisión propone un enum `FieldKind` de 6 valores para elegir campo en
tiempo de ejecución, sobre la premisa de que la superficie es irregular —
`fp_modulus`, `fr_modulus`, `fp_num_bytes`, `fr_num_bytes` y `curve: u32`
presentes con formas distintas.

**Esas cinco cosas tienen cero ocurrencias en todo el repositorio.** La
superficie no es irregular: no hay nada de qué elegir.

- `examples/wasm_fp.zig:9` es `const Fp = zf.BLS12_381_Fp`. El campo es fijo
  en tiempo de compilación.
- Los exports son `fp_add(a_lo: u64, a_hi: u64, b_lo: u64, b_hi: u64, out: [*]u8)`
  sobre 256 bits. No hay `kind` en ninguna parte, ni paramétrico ni de otro modo.
- `wasm_pairing` tiene **7 exports**, no ~4.

Lo que la revisión construyó compensa una superficie **sin costuras por las que
elegir campo**, no una superficie inconsistente. El diagnóstico está equivocado
y el dolor es real; la diferencia importa: arreglar "la inconsistencia" no
arregla nada, porque no hay inconsistencia que arreglar.

**Lo que habría que añadir es un `FieldKind` y un `CurveKind` donde hoy no hay
nada**, lo cual es más trabajo del que su propuesta asume y es una decisión de
diseño, no un parche. Con el dato por delante, la decisión es del propietario.

## 2. P2-7: no hay KAT de Poseidon ni de MiMC, de ningún tipo

La revisión escribe que "los tests sobre F7 con valores esperados están ✓".

**No hay ningún valor esperado.** El test de `root.zig:260` es:

```zig
const h  = p.hash2(a, b);
const h2 = p.hash2(a, b);
try std.testing.expect(h.eql(h2));
```

Afirma `h == h`. Es determinismo, es un round-trip, y **pasa para cualquier
función, incluida una que devuelva siempre lo mismo**. Cero literales hex en
`poseidon.zig` ni en `mimc.zig`.

No es que falte un KAT sobre BN254 Fr: es que **no hay KAT de ningún tipo**. Y
`poseidon.zig` (224 líneas) y `mimc.zig` (85 líneas) **no tienen ni un test
propio** — los dos tests viven en `root.zig`, el agregado. Es la clase de
`.hash()` otra vez: implementación en un fichero, tests en otro.

## 3. P2-6: el README afirma lo contrario de lo que hace el código

La revisión dice que la semántica del ejemplo STARK vive solo en el ejemplo y
es undiscoverable. El problema es más grave que undiscoverable: **el README
afirma lo contrario de lo que hace el código.**

```
README.md:208              "...STARK prover/verifier demo: Fibonacci over
                            Goldilocks with FRI"
examples/stark_prover.zig:48  // Fibonacci transition: next_a = a + b,
                              next_b = next_a (shift)
```

El ejemplo dice *shift*, en un comentario; el README dice *Fibonacci*. Quien lea
el README implementa Fibonacci estándar y obtiene valores distintos. Eso no es
 undiscoverable: es un README que miente, y es el lugar donde la gente mira.

---

## Anexo: lo que sí es cierto y se acepta

- **P0, cuatro métodos públicos que no compilan.** Confirmado y corregido.
  Las líneas reales son `field.zig:663`, `field.zig:1368`, `extension.zig:227`,
  `extension.zig:644` (la revisión citaba 20-28 líneas más abajo, y la
  corrección que nos llegó también). Las dos copias de la extensión tenían un
  **segundo** error no reportado: `hash_val ^= v & 0xFF` con `v: u512`.
- **Alcance del P0**: era lo único corregible sin decisión de diseño. El
  `FieldKind`/`CurveKind`, el KAT de Poseidon y los helpers de límites quedan
  fuera de este commit, con el dato delante.
- **Inventario de alcance público**: 104 métodos públicos en `field.zig` y
  `extension.zig`, 8 sin ninguna llamada en el repositorio (7,7%) a fecha de
  este texto, después de corregir `hash`. Antes eran 12 de 104 (11,5%): hay
  **cuatro** copias de `hash` (dos por fichero), no una.
- **`montgomery`**: hay un advisory abierto y en camino, separado. No se mezcla
  con esto: es un fallo silencioso en una release publicada, esto es una
  ruptura de compilación visible. Distintos advisories, distintos commits.
