# PR #37 follow-up

How each finding in `CLAUDE_REVIEW.md` was resolved. The fixes landed on `main`
after the merge and shipped in 0.14.0.

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | BUG - MEDIUM | A NULL contact/company `name` made `label` non-binary, so core's `Action.new!/1` turned the record's action into `:invalid_action` | **Fixed.** `record_label/1` falls back to the uuid for a blank name or subject on every kind. Tests added, including one that runs every planned action through `Action.new!/1`. |
| 2 | NITPICK | Comments said core 2.23.x does not ship the engine | **Fixed.** Comments updated for core 2.24.0. `@behaviour`/`@impl` still omitted while the requirement is `~> 2.0`. |
| 3 | NITPICK | `nil` answer with a root copy plus another copy reports `:duplicate` instead of `:relocated` | **Not fixed, deliberately.** Documented design (F1); nothing moves either way. |
