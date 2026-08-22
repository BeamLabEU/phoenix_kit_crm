# Review: Fix Catalogue tab 500ing on first load, and declare rustler

**PR:** [#25](https://github.com/BeamLabEU/phoenix_kit_crm/pull/25) (merged `f1199e8`)
**Author:** timujinne
**Branch:** `upstream-fixes/catalogue-tab-500-and-rustler-declare`

## Summary

Two independent fixes:

1. **Catalogue tab KeyError.** `column_picker_available?` and `catalogue_column_catalog()` were only computed in `put_catalogue_columns/2`, which is reached from the column-picker event handlers. The template reads `@column_picker_available` and `@catalogue_column_catalog` whenever `tab == "catalogue"`, so the first render (the only way to reach those handlers) raised `KeyError`. The fix assigns both via `assign_new/3` in `handle_params/3` — the right lifecycle callback (phoenix-thinking: data loading lives in `handle_params`, not `mount`), and `assign_new` is correct so a later picker event's `assign/3` is not overwritten on the next tab switch.

2. **`{:rustler, ">= 0.0.0", optional: true}`** in `mix.exs`, matching phoenix_kit's own declaration, so `MDEX_NATIVE_BUILD=1` can compile `mdex_native` from source. Optional on purpose: a library cannot satisfy a host app's optional-of-optional resolution.

The KeyError diagnosis is right and the `assign_new` placement is right. The PR body claimed a point test ("5/5 passing"); that test is not in the merge.

## Findings

### IMPROVEMENT - MEDIUM — claimed Catalogue-tab test was not in the merge

**Where:** `test/phoenix_kit_crm/web/company_show_live_test.exs`

The PR description says the KeyError is covered by a point test. The merged diff only touches `company_show_live.ex`, `mix.exs`, and `mix.lock`. This suite also cannot 500 through the template path: `phoenix_kit_catalogue` is not a dep, so `catalogue_available?/0` is false, `?tab=catalogue` clamps to Overview, and the template never reads the two assigns. A render-succeeds test would pass *without* the fix.

The assigns *are* set unconditionally in `handle_params` (even when the tab clamps), so the regression is lockable by reading them off the LiveView process.

**Fix applied:** a company-show test that live-mounts `?tab=catalogue` and asserts both assigns are present and well-typed (`boolean` / `list`), so a revert of the two `assign_new` lines fails even when the catalogue module is absent.

### NITPICK — rustler pin is `>= 0.0.0`

Copied from phoenix_kit. Loose, but this is an optional compile-time tool dep, not a runtime contract, and staying in lockstep with core is the point of the declaration. Left as-is.
