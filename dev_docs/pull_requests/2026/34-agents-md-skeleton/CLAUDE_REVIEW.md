# Claude review — PR #34 "Standardize AGENTS.md onto the shared module skeleton" (2026-10-23)

Merged as `4684f2d` (author mdon). Docs only: AGENTS.md rewritten onto the shared
skeleton plus the `CLAUDE.md -> AGENTS.md` symlink. (The #43 review listed this
as "nothing to review"; this is the short read.)

## Findings

None. The file has been edited by every PR since (#40, #42, #43, #45, the V10
commits), so its 2026-09-08 text is not the live one; the current AGENTS.md was
spot-checked instead against the code for the claims a reader acts on:

- `PartyRoleTypes`, `Paths`, the `crm_role_view` / `crm_role_view_locale` route aliases and the `ColumnConfig.view_key/1` scheme all exist as described.
- The Commands section matches `mix.exs` aliases (`test.setup`, `test.reset`, `quality`, `quality.ci`, `precommit`).
- `CLAUDE.md` is a symlink to `AGENTS.md`, so the two cannot drift.
