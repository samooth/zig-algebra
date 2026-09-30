# Respuesta a la revisión externa

Estado: `para enviar`. Idioma: español, el del revisor. No vive en `docs/`
porque no es documentación de la librería sino correspondencia con un tercero,
y porque las afirmaciones de un mensaje externo caducan: las de aquí son
verificadas contra el árbol en `40f4468` (583/583 en ambos modos, 27 binarios);
los dos commits posteriores solo cambian documentación y comentarios, así que el
recuento sigue siendo el mismo. El envío es acción del propietario y este
fichero se queda como registro de lo que se envió.

Los tres puntos de abajo son **correcciones a la descripción de la API que la
revisión da por sentado**, y repetirlas sin corregir serían peores que no
responder: consolidarían una API que no existe.

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

## 2. P2-7: corregido. Ahora hay KAT de Poseidon, y son externos

Cuando esta revisión se escribió, la observación era exacta y grave: el test de
`root.zig:260` afirmaba `h == h` —determinismo, que pasa para cualquier función
—incluida una constante— y no había **ningún** valor esperado. Eso ya no es
cierto, y es lo que hay que responder:

- `poseidon_hash` está anclado a los parámetros **CryptoExperts Hades** (los
  que usa StarkNet: t=3, RF=8, RP=83, alpha=3, S-box parcial en la última
  celda; 107 constantes de `poseidon-py`), expuestos para eso como
  `PoseidonVariant(...)` con `Poseidon(...)` manteniendo la celda 0.
- `initSpec` está anclado al **generador Grain de IAIK/circomlibjs**: las 195
  constantes de ronda, la MDS 3x3 y tres estados de permutación de
  `poseidon_reference.js`, sobre el campo escalar de BN254.
Los dos primeros son el mismo tipo de evidencia que esta revisión pedía:
**literales hex externos, no determinismo.** Y el KAT vive ahora en
`poseidon.zig` y no en el agregado, que era la otra mitad de la observación.

Lo que **sigue en pie**, y conviene no abultarlo:

- **`hash2` no tiene vectores publicados.** Lo anclado es la *permutación*
  (los dos conjuntos de parámetros de arriba), no la salida de la esponja. El
  test de `root.zig:128` afirma `hash2(1, 2) == 3` sobre `F_7`: es un valor,
  pero de una instancia elegida aquí, así que es evidencia de tanto como
  "determinismo" —cualquier implementación podría dar 3 por construcción. La
  criticism original sigue siendo válida en este punto, y es el que queda
  abierto.
- **`mimc.zig` no tiene KAT propio.** No lo hemos instrumentado y no vamos a
  afirmar lo contrario.

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

La observación se queda corta. El código no es un *shift* y no es Fibonacci:

```zig
examples/stark_prover.zig:47-51
    for (1..n) |i| {
        // Fibonacci transition: next_a = a + b, next_b = next_a (shift)
        a[i] = a[i - 1].add(b[i - 1]);
        b[i] = a[i];
    }
```

Con `b[i] = a[i]`, la transición es `a[i] = a[i-1] + a[i-1] = 2·a[i-1]`: **el
ejemplo duplica.** Y la comprobación de restricciones (línea 60) verifica
exactamente eso, así que **la prueba es internamente coherente: lo que se
demuestra es "a se duplica"**. Lo que miente es la prosa, en tres sitios que no
se contradicen entre sí sino con el código:

- `README.md:208` dice "Fibonacci over Goldilocks with FRI";
- la cabecera del ejemplo dice `a_{i+1} = a_i + b_i (Fibonacci step)`;
- la misma cabecera dice `b_{i+1} = a_{i+1} (shift register)` y el campo
  documenta `b[i] = a[i+1]`, cuando el código hace `b[i] = a[i]`: una copia,
  no un desplazamiento.

Quien lea cualquiera de las tres descripciones implementa Fibonacci estándar y
obtiene valores distintos, y quien lea el ejemplo buscando un *shift* tampoco
encuentra uno. No es undiscoverable: es documentación que contradice al código
en el mismo fichero, y es el lugar donde la gente mira.

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
- **Inventario de alcance público**: lo que `zig build assert-check` cuenta
  sobre `field.zig` y `extension.zig` es "104 gross (50 prose) / 54 code", y
  antes de corregir `hash` eran 12 sin ninguna llamada en el repositorio: hay
  **cuatro** copias de `hash` (dos por fichero), no una. Se cita la salida de
  la herramienta y no un porcentaje, porque el denominador depende de una
  definición —qué cuenta como "público" y qué como "llamada"— que no está
  escrita en ninguna parte, y un porcentaje sin esa definición no es un
  número reproducible: es una medida con el objeto cambiado debajo.
- **`montgomery`**: hay un advisory abierto y en camino, separado. No se mezcla
  con esto: es un fallo silencioso en una release publicada, esto es una
  ruptura de compilación visible. Distintos advisories, distintos commits.
