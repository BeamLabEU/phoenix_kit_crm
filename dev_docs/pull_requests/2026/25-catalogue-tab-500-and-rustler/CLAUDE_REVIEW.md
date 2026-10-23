# Claude review — PR #25 "Fix Catalogue tab 500ing on first load, and declare rustler explicitly for mdex_native" (2026-10-23)

Merged as `f1199e8` (author timujinne). Read: the `CompanyShowLive` mount hunk,
the `mix.exs` dep line and its lock entry. A Grok review already exists.

## Findings

None needing a change.

- **NITPICK: the fix was applied twice and both survive.** `assign_new(:catalogue_column_catalog, …)` / `assign_new(:column_picker_available, …)` sit in the pre-load assigns, and `assign_catalogue/3` assigns the same keys again when the catalogue is enabled (`company_show_live.ex:99-106` today). The first set is what stops the `KeyError` in `render/1` when the catalogue is disabled or the company is missing; the second refreshes them on a later `handle_params`. Redundant but correct — leave.

## Checked, clean

- **Cause and cure agree:** the template reads `@column_picker_available` and `@catalogue_column_catalog` unconditionally, but they were assigned only on the catalogue-enabled path, so the first render with the catalogue off raised. Seeding both keys before the branch removes the class of error, not just the one tab.
- **`{:rustler, ">= 0.0.0", optional: true}`** mirrors core's own declaration (`MDEX_NATIVE_BUILD=1` builds `mdex_native` from source, which needs rustler itself), is optional so it is not forced onto consumers, and the lock gained the matching `rustler 0.38.0` entry.
