# Codex review — PR #46 (2026-10-27)

PR: [Fix CRM permission gaps: real accounts, settings sub-key, comment moderation](https://github.com/BeamLabEU/phoenix_kit_crm/pull/46),
by Max Don, merged as `5b732bc`. Reviewed the production diff, surrounding
mirror and LiveView flows, the existing review/follow-up, and core's actual
scope, profile-write, role, and settings implementations. PRs #42–#45
already have Codex reviews; #46 is the recent merge without its own record.

## Findings fixed

**BUG - HIGH: stale placeholder snapshots could authorize writes to a claimed account.**
Both contexts checked `Mirror.placeholder_user?/1` against the caller's
user struct before updating the account. A placeholder claimed after that
struct was fetched still appeared writable, letting a mirror resolution
change the now-real account's name or login email. The form's blank-fill
paths had the same check/read/write race, and could also overwrite fields
populated after their initial read.

All four write paths now use `AccountGuard.update_placeholder_profile/3`.
It re-reads the user under `FOR NO KEY UPDATE`, checks the current source
and confirmation state, and holds the lock through the write. Real and
privileged accounts are returned unchanged. Blank fills check the current
field values under that lock too. Resolution flashes use the returned
user's ownership state. `Mirror` remains pure.

Regression coverage includes stale confirmed users through both contexts,
blank fills after confirmation or a newer profile edit, changed placeholder
ownership, Admin promotion, and deletion. Existing tests continue covering
successful placeholder writes and rollback on invalid profile updates.

**BUG - MEDIUM: the reverse mirror page still exposed privileged organization accounts.**
The contact/company pickers excluded Owner and Admin accounts, but the
Organizations page loaded every organization user and rendered their email,
name, and Create/Link actions to an everyday CRM holder. The reverse picker
also opened for a privileged account even though the final link was refused.

The Organizations list now excludes those accounts using one batched
privilege lookup. The reverse picker validates the UUID, account existence,
organization type, and privilege before opening; rejection also clears any
previous picker state. LiveView tests cover Owner and Admin organization
accounts and invalid/missing picker targets.

## Validation

The pre-change targeted mirror/permission suite passed (121 tests). The new
company regression demonstrated the stale-snapshot failure before the fix.
`mix test` passed: **1,028 tests, 0 failures, 5 excluded**, seed 325323,
with PostgreSQL integration tests enabled. The exclusions are the existing
core ExpectedSchema/ModuleChainCheck feature gates; this resolved core does
not provide those APIs. The focused guard, context, and Organizations suite
also passed after the final refactor: **74 tests, 0 failures**, seed 42.

`mix precommit` passed: forced compilation with warnings as errors, unused
dependency check, Hex audit, formatting check, strict Credo, and Dialyzer
with the repository's existing ignores. No dependency changes or new
Dialyzer ignores were needed.

`mix format` also corrected one pre-existing multiline assertion in
`test/integration/expected_schema_test.exs`; that change is formatting only.
