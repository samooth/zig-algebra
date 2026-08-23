# zig-serialization

Canonical wire encoding for Zig structs via comptime reflection. Zero-copy where possible, deterministic layout guaranteed.

## Features

- **Struct serialization** — encode/decode arbitrary structs via `std.meta.fields`
- **Field-element integration** — types exposing `toBytes`/`fromBytes` are automatically routed through them
- **Golden test** — wire layout is pinned by a golden test to catch accidental format changes
- **Round-trip safety** — nested slices, optionals, and error unions are handled
- **Rejection** — truncated or trailing bytes cause decode errors (no silent truncation)

## Running Tests

```bash
cd libs/serialization && zig build test
```

## License

MIT OR Apache-2.0
