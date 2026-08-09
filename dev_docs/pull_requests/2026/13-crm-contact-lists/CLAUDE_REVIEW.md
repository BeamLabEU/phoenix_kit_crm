# PR #13 Review — Contact lists + account import + list locale (Stage 3)

- **PR:** [#13](https://github.com/BeamLabEU/phoenix_kit_crm/pull/13)
  (`timujinne/feature/crm-contact-lists` → `main`, merged as `1f12fa6`)
- **Scope:** Stage 3 of the restructuring plan — CRM contact lists
  (`PhoenixKitCRM.Lists`), a CSV/plaintext account importer
  (`PhoenixKitCRM.Lists.Import`), per-list locale with a bulk-apply action,
  contact-level opt-out/consent, a directory-wide duplicate-email +
  cross-list-overlap comparison screen, and search/pagination added to the
  existing Contacts/Companies/PartyRoles listings. 51 files, ~6,950
  insertions. The branch already went through two review-fix rounds before
  merge (`e9b06ae` fixed the locale-apply preview count for `:missing_only`;
  `fcbe988` chunked `members_by_email`'s bind params, pre-filtered known
  import collisions before the write transaction, and added the missing
  `list_locale_applied` broadcast) — this is a post-merge review of the final
  merged state, plus the `a2cb6b4` "lib upgrades" commit on top.
- **Findings:** 1 BUG-HIGH (dependency floor below the version that ships a
  migration this PR hard-requires), 1 IMPROVEMENT-HIGH and 1
  IMPROVEMENT-MEDIUM (both "no DB queries in `mount/3`" Iron Law violations,
  inconsistent with the sibling LiveViews in this same PR that get it
  right), 2 NITPICKs. All fixed below.
- **Reviewer:** Claude (Sonnet 5), post-merge.
- **Method:** Phoenix + Ecto lenses (`elixir:phoenix-thinking`,
  `elixir:ecto-thinking`), invoked before reading any code. Read every new
  module in full (`Lists`, `Lists.Import`, `ImportReport`, both new schemas,
  all five new LiveViews) and diffed every modified existing file
  (`Contacts`, `Companies`, `PartyRoles`, `ContactsLive`, `CompaniesLive`,
  the form/show LiveViews, routes/paths/tab registration, mix/config/test
  support files) against `main`. Cross-checked the DB layer against the
  actual core migration (`phoenix_kit/lib/phoenix_kit/migrations/postgres/v152.ex`)
  rather than trusting the schema/moduledoc claims about column types and
  indexes. Applied the Phoenix skill's "no database queries in mount" Iron
  Law systematically across all five new LiveViews, since three of them
  diverge from the pattern the other two (and every pre-existing LiveView in
  this module) already follow correctly.

---

## BUG - HIGH

**The `phoenix_kit` dependency floor (`>= 1.7.197`) is below the version that actually shipped this PR's required core migration — installing at the stated floor would crash with "relation does not exist".**

`mix.exs`'s own comment on the `pk_dep(:phoenix_kit, ...)` line said core
migration V152 (`phoenix_kit_crm_lists`/`phoenix_kit_crm_list_members` DDL,
required by every `PhoenixKitCRM.Lists` function this PR ships) was "not yet
published to Hex as of 2026-07-17", and left the floor at the pre-existing
`>= 1.7.197` since it "can't name it yet". That's now stale: checked core's
own `CHANGELOG.md` and confirmed via `git tag --contains` on the commit that
introduced `v152.ex`'s CRM-lists section — V152 (including the CRM lists
DDL) first shipped in the **1.7.203** tag, not 1.7.197. Every version between
1.7.197 and 1.7.202 inclusive satisfies the stated `mix.exs` constraint but
lacks the tables `PhoenixKitCRM.Lists` unconditionally queries — a real
install following this package's own stated floor would compile and boot
fine, then crash the first time any Lists/Comparison page loads (`ERROR:
relation "phoenix_kit_crm_lists" does not exist`), not caught by
`mix compile` or by this repo's own gate, since none of it runs against a
`phoenix_kit` build below what's actually vendored locally.

**Fix applied:** bumped the floor to `pk_dep(:phoenix_kit, "~> 1.7 and >=
1.7.203")` and rewrote the now-stale comment. Caught during the release
step of this review (checking the version floor against Hex before
publishing) rather than during the initial code read — worth remembering
for future PRs that add a new floor comment promising "bump this once X
ships": the promise is easy to leave unfulfilled once X actually ships.

---

## IMPROVEMENT - HIGH

**`ComparisonLive.mount/3` runs a full-table duplicate-email aggregate query directly in `mount/3` — executed twice per page visit.**

`lib/phoenix_kit_crm/web/comparison_live.ex` had no `handle_params/3` at all;
`mount/3` called `Contacts.list_duplicate_email_groups()` (a `GROUP BY email
HAVING count(*) > 1` scan over the whole non-trashed contacts table) and
`Lists.list_lists(status: "active")` directly. Per the Phoenix skill's Iron
Law, `mount/3` runs **twice** for every browser navigation to this page — once
for the disconnected HTTP render, once again when the LiveSocket connects —
so both queries ran twice on every visit to `/admin/crm/comparison`, with no
way to skip the redundant pass. The cost scales with the size of the contacts
table; on directories with real duplicate-heavy datasets this is exactly the
kind of query the Iron Law exists to keep out of `mount/3`.

This is also an internal inconsistency within the same PR: the other four new
LiveViews split into two that get this right
(`ListFormLive.mount/3` is a no-op, `ListsLive.mount/3` only subscribes/sets
empty defaults — both load data in `handle_params/3`) and — until this
review — three that don't (see the MEDIUM finding below for the other two).

**Fix applied:** added `handle_params/3` and moved both queries there;
`mount/3` now only sets static assigns and empty defaults, matching
`ListsLive`'s existing pattern. No test changes needed —
`ComparisonLiveTest` already exercises the page exclusively via `live/2`
(disconnected + connected mount), so the query-timing fix is transparent to
it.

---

## IMPROVEMENT - MEDIUM

**`ListMembersLive` and `ListImportLive` also query in `mount/3` instead of `handle_params/3`.**

Both `lib/phoenix_kit_crm/web/list_members_live.ex` and
`lib/phoenix_kit_crm/web/list_import_live.ex` called `Lists.get_list(uuid)`
directly in `mount/3` (including the not-found redirect), doubling that
lookup on every page load — the same Iron Law violation as the HIGH finding
above, just against a single primary-key `get` rather than an aggregate scan,
hence the lower severity. Notably, this exact codebase already has the
correct pattern to copy from: `ContactShowLive` (pre-existing) and
`ListFormLive` (new in this same PR) both resolve their `:uuid` param in
`handle_params/3`, not `mount/3`.

**Fix applied:**

- `ListMembersLive`: moved `Lists.get_list/1` (and the assigns that depend on
  it — `page_title`/`page_subtitle`/`page_section*`) into `handle_params/3`,
  merged with the existing filter/page/search parsing that already lived
  there. Left the `if connected?(socket), do: CRMPubSub.subscribe(...)` call
  in `mount/3` — `handle_params/3` on this LiveView re-runs on every
  search/filter/pagination `push_patch`, so moving the subscribe there too
  would re-subscribe the process on every patch instead of once per socket.
- `ListImportLive`: added `handle_params/3` and moved the list lookup (plus
  `page_title`/`page_section*`) there; `mount/3` now only configures
  `allow_upload/3` and the `preview_limit` assign, neither of which depends
  on the list.

Both existing test suites (`ListMembersLiveTest`, `ListImportLiveTest`) call
exclusively through `live/2`, so no test changes were needed to keep them
green — verified by the full `mix test` gate run below.

---

## NITPICK

- **`Lists.Import.apply_result/5`'s catch-all changeset clause mislabels non-email validation failures as `:invalid_email`.** A row whose contact insert fails validation for a reason unrelated to the email (e.g. a CSV `name` cell over 255 chars, which `Contact.changeset/2`'s `validate_length(:name, max: 255)` would reject) is bucketed into the report's `:invalid_email` skip reason, since `ImportReport` has no more granular "rejected for some other reason" bucket. Not fixed: the actual email format is already validated earlier in the pipeline (`Contact.valid_email?/1`, before any write is attempted), so reaching this clause at all requires a narrow edge case (an oversized name, company, or a future field), the failure is still correctly counted as a skip (no data loss, no crash), and the full changeset error is logged via `Logger.warning/1` for anyone investigating a mislabeled row. Flagging so this doesn't get assumed to be exhaustive if `ImportReport`'s taxonomy grows a real `:other`/`:invalid_row` bucket later.
- **`mix.exs` had a stray unindented `#` comment line** (`lib/phoenix_kit_crm/gettext.ex`-adjacent block, line 75) breaking the visual alignment of the surrounding 6-space-indented deps-list comments — a harmless leftover, likely from an earlier edit to that comment block. Fixed inline (indentation only, no content change); `mix format` doesn't reformat comment indentation so this wouldn't have been caught by the gate.

---

## Verified clean (checked, no action)

- **`ListMember`/`ContactList` DB layer matches the schema/moduledoc claims.**
  Cross-checked against `phoenix_kit/lib/phoenix_kit/migrations/postgres/v152.ex`:
  `phoenix_kit_crm_list_members.email` is genuinely `CITEXT` (not just
  documented as such), `idx_crm_list_members_list_email` is a partial unique
  index (`WHERE email IS NOT NULL`) exactly as `ListMember`'s moduledoc
  describes, and `idx_crm_list_members_list_contact` has no status predicate
  — confirming `Lists.add_contact_to_list/3`'s look-up-then-reactivate
  approach (rather than a blind insert) is actually necessary, not defensive
  over-engineering.
- **`Lists.reactivate_member/4` and `remove_member_row/2`'s atomic
  conditional-update pattern is race-safe.** Both use a single
  `WHERE ... AND status == <expected>` `update_all` (not a
  SELECT-then-UPDATE) specifically so two concurrent reactivations/removals
  of the same row can't both read the pre-write status and double-adjust
  `subscriber_count` — verified the guard clause and the fallback branch
  actually cover all three outcomes (own write wins / a concurrent write got
  there first / already in the target state).
- **`members_by_email/3`'s chunking is necessary, not premature
  optimization.** Postgres caps a single query at 65,535 bind parameters;
  `field in ^list` expands to one bind param per element, so an import file
  with tens of thousands of addresses would raise `Postgrex.Error` without
  the `Enum.chunk_every/2` batching. The email-case-insensitivity handling
  (`String.downcase/1` on the map key, since citext preserves stored case) is
  consistent with how the unique index itself compares.
- **`add_new_contact_to_list/3`'s in-transaction PubSub broadcast** — fires
  before the transaction commits rather than after, which every other
  broadcast call site in this module does deliberately after. This is
  documented in the function's own moduledoc as an accepted, negligible-window
  tradeoff for reusing `add_contact_to_list/3` rather than duplicating its
  insert/counter/broadcast logic; `PubSub.broadcast_list_event/2` is also
  best-effort/rescued, so a broadcast racing a (rare) rollback fails silently
  rather than crashing the import.
- **Search refactor (`Contacts`/`Companies`/`PartyRoles`) correctly
  deduplicates `like_pattern/1`** into `PhoenixKitCRM.Search.like_pattern/1`
  — same escaping (backslash/percent/underscore) at the one call site now
  shared by all three contexts, no drift between them.
- **`ContactsLive`/`CompaniesLive` pagination**: count-then-clamp-then-fetch
  order (count first, clamp the requested page to `total_pages`, *then* fetch
  with the clamped offset) correctly prevents a stale/forged `?page=` from
  either crashing or silently rendering an unexplained empty table — checked
  the empty-state copy also correctly distinguishes "no results at all" from
  "no results *on this page*" from "no results *for this search*".
- **Routes**: `/admin/crm/lists/new` vs `/admin/crm/lists/:uuid/edit` don't
  actually collide on segment count (4 vs 5 path segments) despite the
  route comment's phrasing ("`new` must precede `:uuid`") suggesting an
  ambiguity that would need declaration-order to resolve — the comment is
  imprecise but the routes themselves are unambiguous either way.
- **CSV import parsing**: BOM stripping, per-row 1-based `line` numbering
  (matching what a user sees opening the file in a spreadsheet, header row
  counted), and the shared `process_row/6` pipeline between `preview_rows/2`
  (dry-run) and `run`/`run_chunk` (real write) — confirmed the two can't
  drift on `:no_email`/`:invalid_email`/`:duplicate_in_file` classification
  since they're the literal same function, only the terminal resolver
  differs.
- **`ListImportLive`'s chunked run** (`@chunk_size 200`, one `send(self(),
  :process_chunk)` per chunk) actually yields back to the LiveView's mailbox
  between chunks rather than blocking on the whole file — confirmed the
  `confirm_import` button is gated out of the DOM once `@phase` flips to
  `:running` (not just client-side `disabled`), so a forged duplicate
  `confirm_import` event can't restart a second concurrent run against the
  same accumulator.
- **Upload handling**: `entry.done?` is checked server-side before
  `consume_uploaded_entries/3` (not just the template's `disabled=`), and
  `all_upload_errors/1` combines both `upload_errors/1` (config-level, e.g.
  `:too_many_files`) and `upload_errors/2` (per-entry, e.g. `:too_large`) —
  a naive template would only show one or the other.

---

## Gate status (this environment, after fixes)

- `mix format` ✓ (no diff beyond the fixes above)
- `mix compile --warnings-as-errors` ✓ (zero warnings)
- `mix credo --strict` ✓ (99 files, 1134 mods/funs, no issues)
- `mix dialyzer` ✓ — `Total errors: 4, Skipped: 4, Unnecessary Skips: 0`, all
  covered by `.dialyzer_ignore.exs` (Gettext + `Lists.Import`'s documented
  opaque-`MapSet` false positive), `done (passed successfully)`
- `mix test` (`PHOENIX_KIT_PATH=../phoenix_kit`) ✓ — **90 passed, 0
  failures** (312 excluded)

Postgres is not available in this review environment, so `:integration`
(DB/LiveView) tests auto-exclude per the repo's own documented stance
(AGENTS.md "Testing" section) — only unit tests ran. The excluded 312 include
every LiveView test for the fixed files (`ComparisonLiveTest`,
`ListMembersLiveTest`, `ListImportLiveTest`) — the mount/handle_params
timing fixes above are covered by those suites' existing `live/2` calls but
weren't exercised in this run; worth a `PHOENIX_KIT_PATH=../phoenix_kit mix
test` pass against a real Postgres before the next release if one hasn't run
since this PR merged.
