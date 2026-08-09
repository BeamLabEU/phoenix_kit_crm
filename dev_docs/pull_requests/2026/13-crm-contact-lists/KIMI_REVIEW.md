# PR #13 Review (round 2) — Contact lists + import, post-merge hardening

- **PR:** [#13](https://github.com/BeamLabEU/phoenix_kit_crm/pull/13)
  (`timujinne/feature/crm-contact-lists` → `main`, merged as `1f12fa6`,
  reviewed here at `7df54b4` / v0.3.0).
- **Relationship to round 1:** `CLAUDE_REVIEW.md` (same directory) already
  covered this PR post-merge and fixed the dep floor, the three
  `mount/3`-query Iron Law violations, and two nitpicks (commit `7c11bac`).
  This is a second, independent post-merge pass over the same merged state —
  it deliberately does not re-report round-1 findings, and everything below
  was confirmed against the tree *after* `7c11bac`.
- **Findings:** 9 BUG-MEDIUM, 1 IMPROVEMENT-HIGH, 4 IMPROVEMENT-MEDIUM,
  7 NITPICKs — **all fixed in this branch** except two IMPROVEMENT-MEDIUM
  items (the `ListMembersLive` self-echo double reload and the per-row
  import fan-out), which are documented-not-fixed with reasons; plus
  regression tests and a gettext catalog refresh. One further item
  (navigate-away mid-import) is documented as known-not-fixed.
- **Reviewer:** Kimi, post-merge.
- **Method:** eight parallel review lenses, one per PR area (Lists context,
  import engine, each of the five new LiveViews, the Contacts/Companies
  search+pagination changes, the schemas/search layer, and the test suites
  themselves). Every reported finding was then independently verified before
  fixing — by reading the coupled code and, where the claim was "this
  crashes", by reproducing it with `mix run` (e.g. `Integer.parse(["2"])`
  and `URI.encode_query(%{"search" => ["x"]})` both raise; a Latin-1 byte
  sequence survives `String.trim` and reaches the insert path). No finding
  was fixed on a subagent's word alone.

---

## IMPROVEMENT - HIGH

**`Lists.Import.add_row/4` built the report with `rows ++ [row]` — O(n²)
accumulation that defeats the chunked-import design on big files.**

`lib/phoenix_kit_crm/lists/import.ex:416-422` appended one report row per
input row, copying the whole accumulator each time. Benchmarked on this
machine: 10k rows ≈ 0.33 s, 20k ≈ 1.6 s, 40k ≈ 6.6 s — clean quadratic. The
upload limit is 5 MB (~150–250k one-email-per-line rows), so the *preview
alone* (a single unyielding `handle_event`) would stall the LiveView for
minutes; chunking the real run didn't help because `run_chunk/4` threads the
same accumulator across chunks. The engine's own moduledoc claims it handles
"a file near the upload size limit".

**Fix applied:** `add_row/4` now prepends; new public
`Import.finalize_report/1` restores file order with one `Enum.reverse/1`.
`run/3` and `preview_rows/2` return finalized reports as before (their
contract is unchanged); `run_chunk/4`'s doc now states rows accumulate
newest-first, and `ListImportLive` calls `finalize_report/1` once when the
run completes.

---

## BUG - MEDIUM

**1. Forged `toggle_list` uuid crashed the comparison screen.**
`comparison_live.ex:67-82` fed the client-supplied `phx-value-uuid` straight
into `Lists.list_overlap/1`, whose first query is
`where([m], m.list_uuid in ^list_uuids)` — a malformed string raises
`Ecto.Query.CastError` at query normalization and kills the LiveView. The
codebase already knows this failure mode (`Contacts.list_by_uuids/1` drops
malformed ids with the comment "so one bad element can't raise an Ecto cast
error") but that filter ran *after* the membership query. **Fix:** validate
inside `list_overlap/1` with a `valid_uuid?/1` filter (mirroring
`list_by_uuids/1`), return `[]` when fewer than 2 valid uuids remain, and
recompute the distinct-count from the survivors. Context-level fix, so every
present and future caller is covered. Regression test added.

**2. The cross-list overlap report surfaced trashed contacts.**
Trashing a contact only flips `contacts.status`; memberships stay
`"subscribed"`, and `list_overlap/1` resolved contacts via the deliberately
any-status `Contacts.list_by_uuids/1` — so the comparison screen listed
trashed contacts (with live profile links) while its own duplicate-email
report explicitly excludes them (`contacts.ex:82`). **Fix:** reject
`status == "trashed"` in `list_overlap/1` (documented in its @doc).
Regression test added.

**3. Malformed CSV / non-UTF-8 files crashed the import.**
`NimbleCSV.parse_string/2` raises `NimbleCSV.ParseError` on malformed CSV
(e.g. an unterminated quote — verified against `deps/nimble_csv`), and a
Windows-1252/Latin-1 export (Excel's default in many EU locales) is invalid
UTF-8: `String.trim/1` raises on some inputs, and bytes that survive parsing
reach `Contacts.create_contact/1` and make Postgres raise 22021 *inside the
per-row transaction* — killing `handle_info(:process_chunk)` mid-import with
partial rows committed and no user-facing error. **Fix:** `parse_csv`/
`parse_text` now return `[]` for non-UTF-8 content (`String.valid?/1` guard)
and rescue `NimbleCSV.ParseError`; the upload path in `ListImportLive` shows
an explicit "isn't valid UTF-8 text — re-export" flash instead of a
misleading "no rows found". Regression tests added (malformed CSV, Latin-1
CSV, Latin-1 TXT).

**4. The import done-phase rendered every skipped row into the DOM.**
`list_import_live.ex` `:for={row <- Enum.filter(@final_report.rows, ...)}`
per bucket, no cap — a duplicate-heavy re-import (the idempotent re-import
case the engine explicitly supports) renders hundreds of thousands of `<li>`s
plus five full filter passes per render, hanging the browser. The preview
phase already truncated to `@preview_limit`. **Fix:** `@row_detail_limit 50`
per bucket via `bucket_rows/2`, with a "…and N more" note.

**5. The paste-import path had no size cap.** `@max_file_size` only applied
to uploads; `preview_paste` accepted arbitrary text and classified all of it
inside one blocking event. **Fix:** same 5 MB byte cap on the paste path
(plus a `String.valid?/1` check), with a "too large (max %{size})" flash.

**6. No phase guards on import events or `:process_chunk`.** A forged or
replayed `preview_paste`/`preview_upload` mid-`:running` flipped `@phase`
back to `:preview` while queued chunk messages kept writing and eventually
snapped the UI to `:done`; a forged `confirm_import` mid-run spawned a
second chunk loop (idempotent, so no corruption — but wrong progress and
double work). A stray `:process_chunk` outside `:running` pattern-matched a
nil accumulator. **Fix:** `preview_*` only in `:input`, `confirm_import`
only in `:preview`, `:process_chunk` only in `:running` — everything else is
a no-op clause. (Traced the mailbox interleaving first: the double-click
`confirm_import` case was already safe because chunks are consumed exactly
once from assigns.)

**7. Non-binary query params crashed three LiveViews.**
`?page[a]=1` decodes to `%{"page" => %{"a" => "1"}}` and `Integer.parse/1`
raises `FunctionClauseError` (reproduced); `?search[x]=y` survived into the
assigns and then raised in `URI.encode_query/1` when the tab/pagination
links were rendered (reproduced). Affected `ListMembersLive`,
`ContactsLive`, `CompaniesLive` (all three added by/changed in this PR's
pagination+search work), plus a forged `search` event with a non-binary
term and a forged `check_email` with a non-binary email. **Fix:**
`is_binary` guards with fallbacks in `parse_page/1`, the `search` assign,
and both event handlers, in all three LiveViews.

**8. A forged `?search=%00` crashed the list pages; untrimmed terms
silently mismatched.** The list-page search path
(`maybe_search_contacts/companies/roleable/members`) passed the raw term to
`Search.like_pattern/1`, unlike the sibling picker functions which
explicitly strip NUL bytes and trim — a 0x00 byte makes Postgres reject the
query (22021) and crash the LiveView on every visit to that URL, and
`" acme "` (or a whitespace-only term, which became `ILIKE '% %'`) behaved
nothing like the pickers. **Fix:** centralized in
`Search.like_pattern/1` (strip NUL, then trim, then escape — covers all four
callers), and the four `maybe_search_*` sites now treat a trim-empty term
as "no search" instead of a match-everything `%%` pattern. Unit tests added
(new `search_test.exs` — runs without a DB).

**9. `resubscribe`'s bare-`%Contact{}` fallback could wipe the membership's
email slot.** If `member.contact` was nil (only possible after a direct DB
delete — contacts are soft-deleted, so unreachable through app code today),
`list_members_live.ex:116` fabricated `%Contact{uuid: ...}` with
`email: nil`, and `add_contact_to_list/3` would then reactivate the row
*writing `email: nil`* — erasing the denormalized email that the partial
unique index `idx_crm_list_members_list_email` guards. Strictly worse than
a no-op. **Fix:** the nil-contact case now shows an error flash instead.

---

## IMPROVEMENT - MEDIUM

**1. Restore was not activity-logged while trash/delete are.**
`handle_event("restore")` on both Contacts and Companies mutated state with
no `Activity.log`, so the Events feed showed an entity being trashed but
never coming back — an audit-trail gap against the module's "mutations log
`crm.<verb>`" convention. **Fix:** log `crm.contact_restored` /
`crm.company_restored` (uuid-only metadata, no PII) and added matching
`ActivityLabels.describe/2` clauses ("Restored from trash",
`hero-arrow-uturn-left`).

**2. Every `ListMembersLive` mutation reloaded the member list twice**
(explicit `load_members/1` in the handler + the context's own PubSub
broadcast echoing back to this subscribed socket and triggering
`handle_info` → `load_members/1` again — each round is `list_members` +
`get_list!`). **Not fixed, documented:** dropping the explicit reload would
make the UI depend on a broadcast that `broadcast_list_event/2` deliberately
treats as best-effort/rescued; suppressing the self-echo needs an origin
token threaded through the payload, which touches every broadcaster in
`Lists`. Filed as a follow-up rather than half-fixed here.

**3. Per-row activity + PubSub + counter fan-out on large imports.**
Each imported row does its own transaction containing an `Activity.log`
insert, a PubSub broadcast to every admin subscribed to `crm:lists`, and a
counter `update_all` + re-`get!` — 100k rows means 100k of each. This is the
PR's documented "reuse `Lists` verbatim" tradeoff (correctness first), not
a regression introduced by mistake. **Not fixed, documented:** the right
shape is a summary `crm.list_imported` activity entry per run (counts only,
no PII) plus suppressing per-row broadcasts for `source: "import"` — that
changes the audit model and deserves its own PR with a product decision,
not a drive-by in a review branch.

**4. The gettext catalogs never picked up PR #13's strings — every new
screen was English-only in `ru`/`et` locales.**
`priv/gettext/default.pot` shipped 62 msgids against ~385 in the code —
none of the Lists/Import/Comparison UI (or several earlier additions) had
ever been extracted. Not a runtime crash (Gettext falls back to the msgid),
but the module's shipped `ru`/`et` locales silently didn't cover any of
this PR's UI. **Fix:** ran `mix gettext.extract` + `mix gettext.merge` —
catalogs now carry all 385 msgids (307 new, 58 unchanged), with the new
ones untranslated (empty `msgstr` → same fallback behavior as before, now
ready for translators).

> **Operational hazard found while fixing this:** a plain
> `mix gettext.merge` (default fuzzy matching) *guesses* translations for
> near-match msgids — and in this project's Gettext setup those fuzzy
> guesses are served at runtime. It translated "Contact created" as
> "Contact" and "%{count} file" as "%{count} role" (caught by
> `ActivityLabelsTest`, 2 failures). Re-merged with `--no-fuzzy` (0 fuzzy
> entries). Future catalog updates in this repo should use
> `mix gettext.merge priv/gettext --no-fuzzy`, or someone must manually
> review every fuzzy entry before committing — the default is not safe to
> commit blind.

---

## NITPICK

- **`ListsLive.toggle_subscribable` hard-matched `{:ok, _}`** — an
  `{:error, changeset}` would crash with `MatchError`, unlike the
  `archive`/`unarchive` handlers right below it. Fixed: same `with` +
  error-flash pattern.
- **Archived-tab empty state said "No lists yet."** with a "Create first
  list" button. Fixed: `empty_title/1` branches on `@filter`
  ("No archived lists.", no create button).
- **"Would import" stat label was wrong in the done phase** —
  `report_stats/1` was shared between preview and done. Fixed:
  `created_label` attr ("Would import" / "Imported").
- **"5 MB" was hardcoded in two user-facing strings** while the real limit
  lives in `@max_file_size` — guaranteed to drift. Fixed: both derive from
  the attribute via `max_size_label/0`.
- **`Logger.warning` on a rejected import row included the raw email**
  (`import.ex`) — PII in logs, inconsistent with the module's PII posture.
  Fixed: line number + changeset errors only (the line number is enough to
  find the row in the source file).
- **The out-of-range-page fallback in `ListMembersLive` reset the assign
  but not the URL**, so the address bar kept the stale `?page=N` and every
  refresh re-ran the double fetch. Fixed: `push_patch` to the page-1 URL
  (which also drops `page=1` from the query string via `members_path/2`).
- **Wrong direction in a cross-reference comment** — `lists.ex` said
  "same reasoning as `reactivate_member/4` **below**" from a function
  defined *after* it. Fixed: "above".

---

## Verified clean (checked, no action)

- **Round-1's mount/handle_params fixes are correct in all three touched
  LiveViews** — `ComparisonLive` and `ListFormLive` have no patch links so
  no stale-assign risk; `ListsLive` keeps its subscribe in `mount` behind
  `connected?/1` and re-derives `filter` on every patch.
- **Double-`confirm_import` at `:preview` and stray chunk messages**
  interleave harmlessly — each chunk is consumed exactly once from assigns;
  the phase guards added above are belt-and-braces for forged events, not a
  fix for a reachable double-import.
- **`classify_membership_error/1`'s two unique-constraint branches** are
  unambiguous (email violation → `:email`, composite → `:list_uuid`); the
  theoretical FK-conflation edge is unreachable because lists are only ever
  archived.
- **`Search.like_pattern/1` escape ordering** was already correct
  (backslash first); OR-grouping inside every `maybe_search_*` composes
  correctly with the status `where`s.
- **`ListMembersLive` filter whitelist, forged `remove_member`/
  `resubscribe_row` uuids, limit+1 pagination math, and contact preloading**
  are all sound; activity metadata across the whole PR is uuid/count-only.
- **Preview-vs-run parity** in the import engine is structural (same
  `process_row/6`, only the resolver differs) and remains so after the
  accumulator change — `finalize_report/1` is called in both terminal
  positions.
- **Navigate-away mid-`:running`** abandons queued chunks silently — real,
  but idempotent re-import makes it recoverable, and the import is not
  transactional-by-design across chunks; a `beforeunload` warning or a
  resumable-import design is a follow-up, not a review-branch fix.

## Test gaps noted (not all addressed here)

Added in this branch: `search_test.exs` (pure unit tests), malformed-CSV /
non-UTF-8 parse tests, `list_overlap` forged-uuid and trashed-contact
tests. Still open for a follow-up: `ListsLive.unarchive` has no test;
`ListMembersLive`'s `filter`/`next_page`/`prev_page` events and
`members_path/2` URL construction are untested; `ListFormLive` has no
negative-path tests (blank name, duplicate slug, unknown uuid);
`ListImportLive`'s `cancel_upload`/`restart`/`.txt`-dispatch/no-file paths
are untested; the bucket-label assertions in
`list_import_live_test.exs:175-177` are tautological (the labels render
unconditionally) and should assert counts or drop to report-struct level.

---

## Gate status (this environment, after fixes)

- `mix format --check-formatted` ✓
- `mix compile --warnings-as-errors` ✓ (zero warnings)
- `mix credo --strict` ✓ (1153 mods/funs, no issues — one nesting-depth
  refactor in `parse_text` made along the way)
- `mix dialyzer` ✓ — `Total errors: 4, Skipped: 4, Unnecessary Skips: 0`
  (same `.dialyzer_ignore.exs`-covered baseline as round 1)
- `mix gettext.extract` + `mix gettext.merge priv/gettext --no-fuzzy` ✓ —
  catalogs refreshed (385 msgids; the `--no-fuzzy` caveat is documented in
  IMPROVEMENT-MEDIUM #4 above)
- `mix test` (`PHOENIX_KIT_PATH=/workspace/phoenix_kit`) ✓ — **94 passed, 0
  failures** (316 excluded), up from 90 passed before this round; re-run
  and green *after* the gettext catalog refresh as well

Same environment caveat as round 1: no Postgres here, so `:integration`
tests auto-exclude — the new `list_overlap` and import-parse regression
tests and every LiveView behavior fixed above (param guards, phase guards,
done-phase cap, restore logging) should get one
`PHOENIX_KIT_PATH=../phoenix_kit mix test` run against a real database
before the next release.
