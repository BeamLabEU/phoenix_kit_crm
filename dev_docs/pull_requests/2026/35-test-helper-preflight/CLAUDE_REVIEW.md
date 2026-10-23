# Claude review — PR #35 "Test-helper preflight, and drop personal identifiers from the docs" (2026-10-23)

Merged as `c625f18` (author mdon). Read: the `test_helper.exs` hunk, the AGENTS.md
landmine removal, and the path scrub in the PR #27 Codex review. (The #43 review
listed this PR as "nothing to review"; this is the actual read.)

## Findings

None needing a change.

- **NITPICK: the preflight branch is untested on a core that lacks it.** `Code.ensure_loaded?(PhoenixKit.TestSupport.PostgresPreflight)` falls through to `:try_connect` (the old behaviour) on older cores, which keeps the `~> 2.0`-era floor working. With the floor now at 2.38.0 the `else` arm is probably dead; AGENTS.md's TODO about `test_helper.exs` stale rationale is the right place to drop it the next time the file is touched.
- **NITPICK: `Path` rewrites in the #27 Codex review turned absolute paths into `phoenix_kit_crm/lib/…` links that no longer resolve** from the file's location. Cosmetic; the review text is historical.

## Checked, clean

- **`{:error, _reason, message}` is printed to stderr and treated as `:not_found`**, so the integration tests auto-exclude with the real reason instead of a minutes-later pool checkout timeout — the whole point of the change.
- **`:exists` on `:ok`** keeps the rest of the boot unchanged; `LiveDatabaseGuard.check!/1` still runs first.
