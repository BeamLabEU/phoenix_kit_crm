# Claude review — PR #20 "Add a conformance test for the :phoenix_kit requirement" (2026-08-10, re-read 2026-10-23)

Merged as `e4746c3` (author mdon; not in this checkout's merge history). One
file: `test/core_pin_conformance_test.exs`, read in its current form (the
floor has moved to `>= 2.38.0 and < 3.0.0` since).

## Findings

None needing a change.

- **NITPICK: `committed_requirement/0` takes the first `:phoenix_kit, "…"` literal anywhere in `mix.exs`**, comments included. Today the only match is the `pk_dep(:phoenix_kit, "…")` line, so it is right; a future comment that quotes an old pin above that line would be read instead. Anchoring the regex to `pk_dep(` / a dep tuple would close it. Left.

## Checked, clean

- **Admits and rejects the right versions** (`2.38.0`, `2.39.0`, `2.99.4` in; `2.0.0`, `2.37.5`, `3.0.0` out), so both traps — the `~> 2.0.x` single-minor pin and a floor below what the module compiles against — fail the build.
- **Resolution order is sound:** `Mix.Project.config()` first, then the literal in `mix.exs` for the `PHOENIX_KIT_PATH` workflow; a committed `path:` dep leaves neither, and the test flunks with the explanation.
