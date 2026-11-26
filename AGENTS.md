# Instructions

## Coding style

- Single-letter ASCII identifiers are forbidden in Zig and Lua files (`scripts/check-names.lua` enforces this).
- Version lives in `build.zig.zon` only and is injected through `build_options`.

## Tests

Tests live only at the two agreed seams. Do not add `test` blocks inside `src/` (`hk.pkl` enforces this), and do not add a new seam without agreement.

- `tests/runner.zig` (`mise run test`) drives `runner.run` against one fake OS boundary.
- `tests/cli.zig` (`mise run smoke`) drives the compiled `huen-mousenap` executable.

## Checks

Run `mise run check` and `mise exec -- zig build install test smoke` before committing.
