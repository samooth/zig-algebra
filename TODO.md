# Roadmap de corrección de zig-algebra

> Auditoría inicial: 2026-09-25. Zig objetivo: 0.16.0.
>
> Estado: la auditoría terminó; los siguientes ítems siguen pendientes salvo
> que se marquen explícitamente. No sobrescribir los cambios locales existentes
> en `build.zig`, `build.zig.zon` o `libs/fri/src/root.zig` sin revisarlos.

## Verificación reproducible

- [x] `zig build test --summary all` termina correctamente en Debug.
- [x] `zig build test --summary all -Doptimize=ReleaseFast` termina correctamente.
- [x] `zig build stark` compila y ejecuta el prover.
- [ ] `zig build -Doptimize=ReleaseFast` realiza un build real y no un no-op.
- [x] `zig fmt --check` pasa sobre los archivos modificados.
- [ ] Cada submódulo permite `cd libs/<name> && zig build test`.
- [ ] La matriz Linux/macOS/Windows y WASM pasa en CI.
- [ ] El worktree no contiene artefactos temporales no versionados.

## P0 — bloqueadores de release

### FRI

- [x] Corregir los cuatro errores de compilación de `libs/fri/src/root.zig:111,188,447,551`.
- [x] Añadir un degree bound inicial y propagarlo a la configuración, prover y verifier (`libs/fri/src/root.zig:131-152,251-258`).
- [x] Rechazar commitments cuya forma de árbol no coincida con `log_size` y número de hojas.
- [x] Hacer que `verifyPath` compruebe profundidad, índice y longitud de ruta (`libs/merkle/src/merkle_tree.zig:253-273`).
- [x] Rechazar el caso de una sola hoja usado para manufactured proofs.
- [x] Hacer cleanup seguro en errores de `layer_evals`, `residual`, `layers_meta` y `queries` (`libs/fri/src/root.zig:275-279,333-343,441-465`).
- [x] Actualizar `examples/stark_prover.zig:182-204` a la API v2.
- [x] Actualizar `libs/fri/README.md:39-78`.
- [ ] Reconciliar `SECURITY.md:3-55` con la versión real y con una implementación verificada.
- [x] Añadir tests de soundness para degree bound, random data, tampering, paths truncados y commitment shape.

### Constantes y algoritmos criptográficos

- [x] Sustituir el generador BLS12-381 G1 de `libs/curve/src/bls12_381.zig:26-32` por el valor canónico.
- [ ] Añadir un test que compare el generador con el KAT canónico de `libs/pairing/src/bls12_381.zig:465-468`.
- [x] Corregir `expandMessageXmd` según RFC 9380 (`libs/curve/src/hash_to_curve.zig:14-42`).
- [x] Implementar hash-to-field uniforme y encoding de longitud/DST (`libs/curve/src/hash_to_curve.zig:45-71`).
- [x] Exponer clear cofactor y aplicar el `suite_dst` en `hashToCurveWithCofactor` (`libs/curve/src/hash_to_curve.zig:213-239`).
- [x] Añadir un vector oficial de `expand_message_xmd`; los tests de curva completa siguen pendientes.
- [x] Eliminar bytes no inicializados y usar un hash real en `fieldFromCounter` de Poseidon/MiMC (`libs/hash/src/poseidon.zig:184-197`, `libs/hash/src/mimc.zig:67-75`).
- [x] Validar longitudes de seeds y round constants de Poseidon/MiMC.
- [x] Asegurar que la matriz MDS generada sea invertible.
- [x] Corregir Blake2 keyed hashing y validar longitudes de clave (`libs/hash/src/blake2.zig:86-96,195-205`).
- [x] Corregir SHAKE256 para producir el XOF estándar y manejar seeds de múltiplos exactos de 136 bytes (`libs/rng/src/shake256.zig:63-95`).
- [x] Corregir el contador/nonce de ChaCha20 y el caso `max = UINT64_MAX` (`libs/rng/src/chacha20.zig:66-114,155-165`).

### Aritmética y APIs de campo

- [x] Reparar la división multi-limb de `BigInt` (`libs/bigint/src/bigint.zig:393-468`).
- [x] Añadir tests de división multi-limb, overflow, signos y `mod`.
- [x] Corregir `limb.subWithBorrow` para `b + borrow` overflow (`libs/bigint/src/limb.zig:58-64`).
- [x] Hacer que `BigInt.fromU128` rechace `max_limbs < 2` y proteger `fromI64(minInt)`.
- [x] Corregir `BigField.isNegative` y `lexicographicCmp` para convertir desde Montgomery (`libs/field/src/field.zig:1136-1156`).
- [x] Corregir `SmallField.randomBounded` y `BigField.randomBounded` (`libs/field/src/field.zig:271-280,923-935`).
- [x] Añadir tests para `bound = 1`, `bound = MODULUS` y fields grandes.
- [x] Completar `CubicExtension.ctSelect` incluyendo `c2` (`libs/field/src/extension.zig:451-457`).
- [x] Hacer válida la construcción de `CubicExtension` para todos los primos soportados.
- [x] Añadir `NUM_BYTES`, `fromBytes` y `toBytes` coherentes a extensiones.
- [x] Eliminar imports rotos de `libs/field/src/lib.zig:14-16,40-47,252-254` o añadir las dependencias correctas.

### IPA, Merkle y serialización

- [x] Marcar explícitamente `Ipa.verify` como no disponible hasta corregir su verifier (`libs/field/src/ipa.zig:220-274`).
- [x] Corregir `verifyWithCommitment` usando los desafíos de cada ronda (`libs/field/src/ipa.zig:228-282`).
- [x] Reactivar los tests IPA actualmente desactivados (`libs/field/tests/ipa_test.zig:4-17`).
- [x] Hacer que `MerkleTree.verify` vincule el índice al path (`libs/merkle/src/merkle_tree.zig:210-248`).
- [x] Hacer coherentes root, leaf count y proofs de MMR (`libs/merkle/src/mmr.zig:140-232`).
- [x] Hacer que `SparseMerkleTree` soporte realmente profundidad 256 (`libs/merkle/src/sparse_merkle.zig:30-44,75-112`).
- [x] Rechazar colisiones de índices de Sparse Merkle y fijar la altura de bits.
- [x] Hacer que serialización detecte los campos reales mediante `NUM_BYTES`/`toBytes` (`libs/serialization/src/root.zig:52-55`).
- [x] Evitar fugas al rechazar trailing bytes (`libs/serialization/src/root.zig:44-49`).
- [x] Añadir límites de longitud, validación estricta de booleanos/optionals y cleanup genérico.

### Pairings, KZG y WASM

- [x] Implementar `Fp6.inv` correctamente (`libs/pairing/src/root.zig:123-127`).
- [x] Unificar la API de BN254: `bn254_tower_pairing` es la ruta canónica y las implementaciones legacy/direct quedan explícitas.
- [x] Añadir KAT EIP-197 al path BN254 público mediante el KAT existente en `bn254_tower.zig`.
- [x] Manejar correctamente el punto infinito en KZG (`libs/kzg/src/root.zig:189-196`).
- [x] Rechazar polinomios vacíos y commitments/witness inválidos.
- [x] Añadir subgroup checks a pairing y WASM.
- [x] Evitar panic en `pairing_compute` con puntos de baja orden.
- [x] Corregir `examples/wasm_fp.zig` para escribir el resultado canónico completo en memoria.
- [x] Retornar error controlado para `fp_inv(0)`.
- [x] Actualizar el smoke test WASM para comprobar high words, subgroup y vectores oficiales.

## P1 — alta prioridad

### Constant-time y seguridad de entradas

- [x] Eliminar ramas dependientes de secretos en `Montgomery.add/sub/mul` (`libs/field/src/montgomery.zig:167-213,225-274`).
- [x] Revisar las afirmaciones constant-time de `roots.sqrt` y documentar la dependencia del resultado opcional (`libs/field/src/roots.zig:33-46`).
- [x] Documentar que `scalarMul` no es apto para escalares secretos (`libs/curve/src/weierstrass.zig:72-80,259-265`).
- [x] Hacer que `randomFieldElement` funcione con `zig-field` y elimine el buffer fijo de 32 bytes (`libs/rng/src/rng.zig:20-55`).
- [x] Hacer thread-safe `setEntropy` y `setRandomForTesting`, o separarlos detrás de APIs de test.
- [x] Implementar entropy Windows mediante `BCryptGenRandom` (`libs/rng/src/csprng.zig`).
- [x] Sustituir asserts de validación pública de los bounds RNG por errores tipados (`libs/rng/src/rng.zig`, `libs/rng/src/chacha20.zig`).
- [ ] Sustituir los asserts de validación pública restantes por errores tipados.

### NTT, polinomios y proof stack

- [x] Corregir `inttWithTwiddles` usando twiddles inversos (`libs/ntt/src/root.zig:149-162`).
- [x] Añadir test de round-trip con precomputación.
- [x] Proteger `Polynomial.x()` para `max_degree == 0` (`libs/poly/src/poly.zig:61-67`).
- [x] Evitar overflow en `Polynomial.pow` (`libs/poly/src/poly.zig:297-309`).
- [x] Manejar `vector.powers(..., 0)` (`libs/poly/src/vector.zig:19-24`).
- [x] Revisar límites, validación y cleanup de `Sumcheck`, `MlePcs` y `CommittedMlePcs` (`libs/binary-field/src/sumcheck.zig`, `libs/binary-field/src/pcs.zig`).
- [x] Exportar `pcs.zig` y corregir el commitment de `CommittedMlePcs` (`libs/binary-field/src/root.zig`, `libs/binary-field/src/pcs.zig`).
- [x] Añadir tests de recursos y rechazos en OOM de las asignaciones parciales de Sumcheck, MlePcs, CommittedMlePcs y Merkle.

### Builds y ejemplos

- [x] Añadir `zig-field` al módulo FRI de `build.zig:335-342`.
- [x] Añadir `zig-field` al build standalone de FRI (`libs/fri/build.zig:29-46`).
- [x] Hacer que el test raíz incluya los tests externos de field, curve y PCS.
- [x] Reparar los ejemplos que usan `std.io.getStdOut`:
  - `libs/algebra-traits/src/main.zig:160`
  - `libs/bigint/src/main.zig:7`
  - `libs/hash/src/main.zig:62,71`
  - `libs/merkle/src/main.zig:8,15`
  - `libs/poly/src/main.zig:67`
  - `libs/rng/src/main.zig:64,71`
- [x] Reparar `libs/ntt/build.zig:43` o eliminar el ejemplo inexistente.
- [x] Añadir `zig-field` al ejemplo de linalg.
- [x] Reparar la API obsoleta de `libs/pairing/src/main.zig`.
- [x] Reparar `PolyF7.init()` recursivo y `deinit()` inexistente en `libs/algebra-traits/src/main.zig:112-114,205`.
- [x] Añadir `isZero` al F7 del ejemplo de hash.
- [ ] Convertir `zig build -Doptimize=ReleaseFast` en un smoke test real.
- [x] Ejecutar todos los tests también con `ReleaseFast`.

### Empaquetado y documentación

- [ ] Eliminar la dependencia local `/tmp/bsvz.tar.gz` de `build.zig.zon:7-14`.
- [ ] Eliminar la autodependencia `zig_algebra`.
- [ ] Hacer reproducibles los paquetes path de los submódulos.
- [ ] Reconciliar versiones `0.3.0`/`0.3.1` y el advisory FRI.
- [ ] Actualizar `README.md:62-80` con los conteos reales.
- [ ] Actualizar `docs/architecture.md:5` y `DESIGN.md:142` de 14 a 17 librerías.
- [ ] Actualizar READMEs de FRI, KZG y parallel.
- [ ] Añadir vectores oficiales de Blake2, Keccak/SHA3, Poseidon, MiMC y field.
- [ ] Marcar explícitamente qué APIs son production, demo o experimentales.

## Criterios de cierre

- [ ] No existe ningún `TODO` de seguridad critiques sin test de regresión.
- [ ] `zig build test` pasa sin depender de tests no conectados al build raíz.
- [ ] `zig build stark`, WASM y ejemplos compilan.
- [ ] Ningún test tarda indefinidamente por rejection sampling.
- [ ] No hay asserts eliminados en ReleaseFast que dejen pathways fuera de rango.
- [ ] Los puntos externos validan on-curve, subgroup y encoding.
- [ ] Los serializadores tienen límites de recursos y liberan memoria en todos los errores.
- [ ] Los claims de constant-time están respaldados por tests o auditoría de assembly.
