# PR #2 — Follow-Up

**Author of follow-up:** Claude Opus 4.7 (1M context)
**Date:** 2026-05-04
**Status:** All five items deferred to the backlog. PR is `APPROVE` per `CLAUDE_REVIEW.md`; no follow-up commits planned for this branch.

This document records the disposition of each finding in `CLAUDE_REVIEW.md`. Mirrors the convention from PR #1's `FOLLOW_UP.md`. Each entry maps to a numbered finding in the review.

## Disposition

### #1 — `handle_params/3` patch-nav footgun (LOW)

**⏸ DEFERRED.** Not exercised today — sidebar nav uses `push_navigate`, no patch-link between role URLs in the codebase. If/when a patch-link gets added between roles, this rerun-on-params split needs to happen first. Until then it's latent footgun, not a live bug.

**Cheap fix when picked up:** read `role_uuid` from `params` in `handle_params/3` and reload `role` / `scope` if it differs. Alternatively (cheaper but less safe) — add an inline comment in `mount/3` documenting that patch-nav between role URLs is unsupported.

**Files:** `lib/phoenix_kit_crm/web/role_view.ex:60-69`

### #2 — `Paths.role/1` empty-string guard is narrow (LOW)

**⏸ DEFERRED.** All current callers pass a DB-loaded UUID; the `is_binary` + empty-string guard is sufficient for that contract. Tighten only if `role_uuid` ever starts flowing from external input (URL params decoded outside a typed schema, CSV import, etc.).

**Tighten when picked up:** add a UUID format check (e.g., `:uuid` Ecto.UUID parse) and reject whitespace / path-traversal inputs. Or wrap `Paths.role/1` in a function on the LiveView that takes a `%Role{}` struct rather than a raw string.

**Files:** `lib/phoenix_kit_crm/paths.ex:14`

### #3 — Hotfix scope is broader than strictly required (NIT)

**✅ INTENTIONAL — no action.** Defensive consistency: every CRM-module tab path is now absolute, regardless of whether its registration route applies `Tab.resolve_path/2` or not. This avoids a future contributor accidentally hitting the same crash on a tab they thought went through `resolve_path` but didn't.

The real fix (load-bearing) was `admin_crm_companies` and `SidebarBootstrap.role_tab/1`. The other two tabs (`admin_crm`, `admin_crm_overview`) were converted along with them for symmetry.

**Files:** `lib/phoenix_kit_crm.ex` `admin_tabs/0`

### #4 — Bilingual msgids will need clean splits (LOW)

**⏸ DEFERRED — host-app concern.** The two `"... / Юрлица"` strings are intentionally bilingual single-string msgids. They render identically in any locale today (the host app's gettext fallback returns the msgid unchanged). When a host app actually localizes, the split will be:

- `gettext("CRM — Companies / Юрлица")` → drop `Юрлица`, become `gettext("CRM — Companies")`; ship `priv/gettext/ru/.../default.po` with the Russian translation `"CRM — Юрлица"` or `"CRM — Компании / Юрлица"` (host's choice).
- `gettext("Companies / Юрлица")` → split similarly.

This is a single-PR refactor whenever the i18n strategy is decided. Tracked here so it doesn't drop off the radar.

**Files:** `lib/phoenix_kit_crm/web/companies_view.ex:35,61`

### #5 — Smoke-test acceptance criterion in CONTRIBUTING (PROCESS)

**⏸ DEFERRED — needs CONTRIBUTING.md.** No `CONTRIBUTING.md` in the repo yet. When the file lands (or the maintainer decides to add one), include this paragraph or equivalent:

> **Sidebar / tab / routing changes:** Before requesting review on any change that touches `admin_tabs/0`, `Tab` registration, `SidebarBootstrap`, or `Paths`, smoke-test the affected admin pages in a host-app dev instance. Static analysis cannot catch path-resolution bugs (see PR #2's hotfix for a worked example).

Until then, treat this as institutional knowledge — flag it in PR descriptions for routing-touching changes.

## Summary

| # | Severity | Disposition |
|---|----------|-------------|
| 1 | LOW | ⏸ Deferred — latent, not live |
| 2 | LOW | ⏸ Deferred — defensive only |
| 3 | NIT | ✅ Intentional |
| 4 | LOW | ⏸ Deferred — host-app concern |
| 5 | PROCESS | ⏸ Deferred — needs CONTRIBUTING.md |

No follow-up commits planned for the `followup/cleanup-i18n-hotfix` branch. Items #1, #2, #4 should land as separate small PRs when the project gets to them. Item #5 lands with the next docs/process PR.
