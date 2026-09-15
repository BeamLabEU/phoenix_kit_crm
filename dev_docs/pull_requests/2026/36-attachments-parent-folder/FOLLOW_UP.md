# PR #36 follow-up

How each finding in `CLAUDE_REVIEW.md` was resolved. The fixes landed on `main`
after the merge and shipped in 0.13.0.

| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | BUG - HIGH | `Images` lookup fell back to the storage root and picked up a host's own `Images` folder | **Fixed.** `find_or_create/4` takes its lookup. `Images` uses `get_folder_under/2` (strictly inside the record folder), including the lost-race re-lookup. Test added. |
| 2 | BUG - MEDIUM | Reads pass no actor, so an actor-dependent (or re-pointed) parent stranded folders, broke avatars and purge, and twinned per actor | **Fixed.** Record folders resolve by name anywhere, preferring the configured parent, then the root, then the oldest (`prefer_parent/2`). The hook only places new folders. Test added (covers purge). |
| 3 | BUG - MEDIUM | Timeline listing skipped trashed folders; the composer still wrote into them | **Fixed.** Batch listing uses the same resolution as the single resolver (`DISTINCT ON (name)` + `prefer_parent/2`). Pre-PR trashed-folder handling restored. |
| 4 | IMPROVEMENT - MEDIUM | `subject` documented but never passed | **Fixed.** Record/interaction uuid passed on every per-record call; the batch listing makes one subject-less call (documented). |
| 5 | NITPICK | A stale parent uuid makes uploads fail with `:folder_unavailable` | **Not fixed, deliberately.** A loud failure beats silently scattering folders at the root; the host owns its container. |
| 6 | NITPICK | CHANGELOG under `## Unreleased` | **Resolved.** Folded into the 0.13.0 entry. |
