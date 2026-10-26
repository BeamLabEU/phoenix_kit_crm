# PR #46 — permission sweep: review record

**Author:** Max Don (with Claude)
**Reviewers:** codex (both rounds); findings checked against the code by Claude before fixing
**Verdict:** every confirmed finding fixed in this PR, each with a test that fails when the fix is reverted.

The sweep's rules: a sub-key `<base>.<sub>` is checked with `Scope.can?/2` in `mount/3` and every write
event against the live scope; new sub-keys are backfilled once to current base-key holders, with the
flag set only after every grant succeeded. Round 1 reviewed the whole change, round 2 only the fixes.

## Findings

- BUG-MEDIUM — the link picker listed Owner/Admin accounts with emails → fixed: `AccountGuard`, refused server-side too.
- BUG-MEDIUM — a live patch to a system role's page skipped the access check → fixed: re-checked on every param change.
- BUG-MEDIUM — the settings check used `Scope.can?/2`, which needs the module on → switched to `has_module_access?`; round 2 noted core's admin gate still refuses a disabled module's page first, so docs and the test name now say exactly that.
- BUG-MEDIUM — the backfill trusted a lookup that swallows DB errors → fixed: own raising query.
