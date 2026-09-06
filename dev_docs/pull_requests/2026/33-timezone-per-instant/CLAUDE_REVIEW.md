# PR #33: Interaction times in the viewer's zone; V6 keeps the zone they were typed in

**Author**: @mdon (merge `935a42e`, branch `mdon/pr/timezone-per-instant`, 4 commits: `ea297d4`, `5dee332`, `13f6fe1`, `f674de1`, `c672f0c`)
**Reviewer**: Claude, single pass — full diff read line-by-line with surrounding context, every core helper the PR now delegates to read in `deps/phoenix_kit` (`Utils.Date.{shift_to_offset,parse_datetime_local,format_datetime_local,get_user_timezone}`, `Utils.TimeZone.{shift,from_wall,offset_seconds,identifier?,legacy_offset?,parse_offset,label}`, `Settings.{get_setting,get_timezone_label}`, `Users.Auth.User.validate_user_timezone/1`, core migration V181), plus real execution of the project's gate and `mix test` against a local `phoenix_kit` checkout and a live Postgres
**Date**: 2026-09-06
**URL**: https://github.com/BeamLabEU/phoenix_kit_crm/pull/33

## Context

19 files, +635/-344 (about two thirds of that regenerated gettext). One bug,
fixed in three layers:

`InteractionHelpers.tz_offset/1` turned the viewer's stored timezone into an
**integer number of hours** with `Integer.parse/1`. Since core moved the
setting to IANA identifiers, `Integer.parse("Europe/Tallinn")` is `:error` →
`0`, so on every account that had touched the timezone picker: the timeline
rendered UTC, the composer's "now" prefill was UTC, and a hand-typed local
time was stored hours off. The PR replaces the scalar with the stored value
itself (`viewer_tz/1`, an IANA id or a legacy offset, never a number) and
routes every conversion through core's per-instant helpers, so a named zone
follows daylight saving **on the date typed** rather than on today's offset.
`tz_offset` → `tz` renames the assign through `CRMLive`, both show LiveViews,
`InteractionsComponent` and `EventsComponent`.

Three supporting strands:

1. **Migration V6** adds `phoenix_kit_crm_interactions.time_zone`
   (`varchar(64)`, nullable) — the zone the wall clock was typed in, stamped
   by the composer on save, including the blank-When path that lets the schema
   default `occurred_at` to now (`c672f0c`).
2. **An unreadable "When" is a save error**, not a silent "now" — a browser
   without a real `datetime-local` widget posts free text, and the schema
   default would have stamped it (`5dee332`).
3. **The `CrmWhenWarnings` JS hook** re-derives the field's instant with the
   browser's own tz database at the field's own date, resolving a repeated or
   skipped wall clock the way the server does (`13f6fe1`) — first occurrence
   for a fall-back hour, the jump instant for a spring-forward gap.

## Findings

### Verified correct — the parts most likely to be wrong, and why they are not

Checked against the producing code, not the PR description. Recorded because
each is a place a future change can silently break.

1. **`viewer_tz/1` really does match core's precedence, and hand-writing it is
   justified.** Core's `Utils.Date.get_user_timezone/1` is `user.user_timezone`
   — on a bare map without the key that is a `KeyError`, which is exactly what
   the old `tz_offset/1`'s blanket `rescue _ -> 0` was papering over. `Map.get/2`
   is the honest fix. The one divergence is deliberate and safer: core returns
   `""` as-is where this returns the site setting, and core's own
   `validate_user_timezone/1` normalises `""` to `nil` on write, so the two
   cannot disagree on a value that can actually be stored.

2. **The `:error` save path is not reachable from a supported flow.**
   `local_to_utc/2` reports `:error` for both an unreadable *value* and an
   unresolvable *zone*, and the user-facing message only speaks to the first.
   That conflation is safe today because both writers of a zone validate it:
   `User.validate_timezone_offset/2` and `Settings.change_settings/1` both go
   through `TimeZone.valid?/1` (`identifier?` or `legacy_offset?`), which is
   the same predicate `from_wall/2` branches on. A zone that reaches
   `from_wall/2` and fails it cannot have been stored through the admin UI.

3. **The composer stamps `time_zone` on both save paths.** `maybe_put_occurred_at/3`
   has a clause for `nil` (blank When → schema default "now") as well as for a
   parsed `%DateTime{}`; a row saved at "now" carries its zone too. Without the
   `nil` clause the rows the PR exists to make repairable would have been the
   ones missing the answer.

4. **`varchar(64)` is not an arbitrary width** — it is core's, from migration
   V181, which widened `phoenix_kit_users.user_timezone` to exactly 64 for the
   same values. The schema's `validate_length(:time_zone, max: 64)` is on
   *both* changesets, and `@castable` carries `:time_zone` so the create
   changeset and the edit changeset agree.

5. **V6 is a correct chain step.** `@current_version` 6, `v6_statements/1`
   appended to `up_statements/1` before the marker `COMMENT`, `ADD COLUMN IF
   NOT EXISTS` so a full replay is idempotent, and `down_statements/2` still
   only rewrites the marker — the ownership test that forbids `DROP`/`TRUNCATE`
   in any emitted statement still holds. Migration tests were bumped 5 → 6 in
   all four places (`current_version`, the marker assertion,
   `migrated_version_runtime`, the replay assertion).

6. **The JS hook's DST resolution matches the server's.** For an ambiguous
   fall-back wall clock it collects both candidate instants and returns
   `Math.min` — the *first* occurrence, which is what `TimeZone.resolve_wall/1`
   picks. For a gap it bisects to the instant the new offset takes over, which
   is what core returns. A zone id the browser cannot resolve falls back to the
   server-supplied offset-now instead of throwing.

7. **`offset_minutes_now/1` fixed a second, quieter bug.** The old
   `data-profile-offset` was whole hours, so every account on a half-hour zone
   (`"5.5"`, Kolkata/Colombo; `"9.5"`, Adelaide/Darwin) saw the "this device is
   somewhere else" warning permanently, on a correctly configured machine.
   Minutes make it exact.

8. **No stale call site survives the rename.** `tz_offset/1` has no remaining
   reference in `lib/`, `test/` or the design doc; `format_local/2` kept its
   arity so no caller silently kept an old meaning. `priv/static/assets/phoenix_kit_crm.js`
   is the single copy of the hook (registered via `lib/phoenix_kit_crm.ex:286`),
   so there is no second, unpatched inline version to drift.

### IMPROVEMENT - HIGH — `CRMLive` resolved the viewer's zone in `mount/3` (fixed)

`lib/phoenix_kit_crm/web/crm_live.ex:48` — the PR edited this line, and left it
in `mount/3`:

```elixir
tz: viewer_tz(socket.assigns[:phoenix_kit_current_user]),
```

`viewer_tz/1` falls through to `PhoenixKit.Settings.get_setting("time_zone", "0")`
whenever the viewer has no profile timezone — the default state of every
account that has not opened the picker — and that is an **uncached**
`repo().get_by/2` (`Settings.get_setting/1` → `Queries.get_setting_by_key/1`;
the settings cache is only invalidated there, not read). `mount/3` runs twice,
so the Overview paid for it twice per page load.

The file argues against itself two functions later, in `handle_params/3`:

> All DB reads wait for the connected mount — the dead render would pay for
> them and then throw the result away.

Both show LiveViews already resolve `tz` in `handle_params/3`; only the
Overview did not.

**Fixed** — `mount/3` seeds `tz: "0"` (the dead render has `recent: []`, so
nothing formats a time before `handle_params/3` runs) and the connected branch
of `handle_params/3` assigns the real value, matching the two show LiveViews.

**Test added** — `crm_live_test.exs`, "the recent feed renders each interaction
in the viewer's zone, per its own date": two interactions, one on each side of
the Tallinn DST boundary, asserted as `10:00` in January and `11:00` in July
from the same `08:00Z`. It fails (`2026-01-15 08:00`) if the `handle_params/3`
assign is removed, and would have failed against the pre-PR integer conversion.
This was the one page the PR changed that had no coverage for the change.

### IMPROVEMENT - MEDIUM — the JS hook could not read a value with seconds (fixed)

`priv/static/assets/phoenix_kit_crm.js`, `wallToUtc/3`:

```js
var asUtc = Date.parse(wall + ":00Z");
```

The server's reader tolerates both shapes — `Utils.Date.parse_naive_datetime_local/1`
tries `str <> ":00"` and falls back to parsing `str` whole — precisely because a
`datetime-local` value can come back with seconds. The hook could not: a value
like `2026-01-15T10:00:30` becomes `...T10:00:30:00Z`, `NaN`, and all three
warnings (past / future / device-mismatch) silently stop rendering. The input
carries no `step`, so browsers currently use minute precision and this is
latent — but the two readers of the same field should not disagree about what
the field can contain, and the failure mode is silence.

**Fixed** — the `:00` is appended only when the value does not already end in
`:SS`.

### IMPROVEMENT - MEDIUM — `time_zone` is written and never read (recorded, not changed)

Nothing reads the column. Every render still formats `occurred_at` in the
*viewer's* zone, which is right — an instant should show where you are, not
where the author was — and the design doc is explicit that the column exists so
a row "can be re-resolved on its own later". That is a sound reason to write it
now and a bad reason to build a reader now.

Two things to know before one is built:

- `Interaction.update_changeset/2` **casts** `:time_zone`, but
  `Interactions.update_interaction/4` has no caller in `lib/` — there is no
  interaction edit UI. The first edit form that lets someone change
  `occurred_at` must re-stamp `time_zone` in the same `attrs`, or the row's
  zone becomes a claim about a wall clock nobody typed. Adding a guard for a
  call site that does not exist would be speculative; this note is the record.
- The column is nullable and every row written before 2026-09-06 is `nil`.
  A reader needs a defined answer for `nil` (the viewer's zone is the only
  honest one) rather than treating it as UTC.

### IMPROVEMENT - MEDIUM — sibling timestamps on the same pages still render raw UTC (recorded, not changed)

`lib/phoenix_kit_crm/web/contact_show_live.ex:429` (the Orders tab's order
date) and `lib/phoenix_kit_crm/web/comparison_live.ex:148` (a duplicate
contact's "added" date) both call `Calendar.strftime(dt, "%Y-%m-%d")` on a
stored UTC value. On the contact page that now means the Interactions tab shows
Tallinn time while the Orders tab beside it shows UTC — for a date-only field
that is a wrong day for anyone east of UTC between midnight and their offset.

Not fixed: neither is an interaction time, so both are outside this PR's scope,
and doing it properly needs a date-only sibling to `format_local/2` plus a `tz`
assign on `ComparisonLive`, which has none. Worth its own change.

### NITPICK — a comment left behind by the rewrite (fixed)

`interactions_component.ex` — `# "Now" in the user's timezone, formatted for a
datetime-local input.` was left sitting directly above the new `zone_id/1`,
which is not what it describes; `local_now_str/1` moved down and grew its own
comment. Removed.

### NITPICK — the prefill assertion can flake on an hour boundary (recorded, not changed)

`company_show_live_test.exs`, "the composer reads and shows times in the
viewer's zone": the prefill is compared at `String.slice(0, 13)` —
`YYYY-MM-DDTHH` — to dodge a minute-boundary race, which still leaves an
hour-boundary one (the page renders at `14:59:59.9`, the assertion computes
`15`). The window is ~1 in 3600 per run and the suite's stability check varies
the seed, not the clock. Left as is; making it exact means asserting against
two candidate hours, which costs more legibility than the flake costs.

## Fixes applied

| File | Change |
|---|---|
| `lib/phoenix_kit_crm/web/crm_live.ex` | `tz` resolved in the connected branch of `handle_params/3`, not in `mount/3` |
| `priv/static/assets/phoenix_kit_crm.js` | `wallToUtc/3` accepts a value that already carries seconds |
| `lib/phoenix_kit_crm/web/interactions_component.ex` | removed the stranded comment above `zone_id/1` |
| `test/phoenix_kit_crm/web/crm_live_test.exs` | new test: the Overview's recent feed renders in the viewer's zone, per instant |

## Validation

- `mix format --check-formatted` — clean
- `mix credo --strict` — 1638 mods/funs, no issues
- `mix compile --force --warnings-as-errors` — clean
- `mix dialyzer` — clean
- `PHOENIX_KIT_PATH=../phoenix_kit mix test` — 735 tests, 0 failures

`test/phoenix_kit_crm/schema_owner_guard_test.exs` and
`schema_owner_guard_wiring_test.exs` (7 tests) cannot run in this sandbox: they
provision a scratch database, which needs `CONNECT` on the `postgres`
maintenance database, and the sandbox's Postgres role does not have it
(`FATAL 42501 permission denied for database "postgres"`). They fail before
reaching any assertion, in `setup`, and their pool timeouts starve one
unrelated LiveView test in the same run — which passes on its own and in a run
that excludes those two files. Environmental, not a finding.

## Verdict

The diagnosis is right and the fix is at the right layer: the bug was turning a
zone into a number, and the repair is to stop doing that everywhere at once
rather than to special-case IANA ids. Delegating to core's per-instant helpers
instead of re-deriving offsets locally is what makes the DST cases correct, and
the V6 column is the right response to having discovered rows that could not be
repaired. The three things this review changed are a doubled settings query on
the one page that kept its old shape, a browser-side reader that was stricter
than its server-side twin, and the missing test on the Overview.
