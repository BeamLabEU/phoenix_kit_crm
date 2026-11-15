# Review: changes since Hex 0.19.0 (unpublished 0.20.0)

**Reviewer:** Grok
**Range:** `v0.19.0` (`0d3f89c`) .. working tree
**Hex:** 0.19.0 is the latest published release. Local `main` already carries the 0.20.0 version bump and changelog. This review does not publish.

## What shipped in the range

Seven commits raise the core floor to `>= 3.5.0 and < 4.0.0` (locked 3.6.0), drop the feature-detection kept for older cores, show role labels instead of role keys, and mark the hooks bundle `scope: :admin`. The managed-mirror option is always compiled in. Core 3.5.0's `js_sources` compiler matches `%{app, file, global}` and rebuilds that map, so `scope` and `hooks` are ignored there and the bundle still loads on public pages. Core 3.6.0 honours them. That split is real; the changelog now says so.

The behaviour tests for role labels, the admin hook list, the mirror blank-name workaround, and managed creation were already green before this review.

## Findings

### 1. BUG - MEDIUM — the test helper still told people the published core has no CRM tables

`test/test_helper.exs` probed `phoenix_kit_crm_contacts` *after* this module's own chain had created it, then, on a miss, printed `PHOENIX_KIT_PATH=../phoenix_kit mix test`. That probe cannot fail once the chain has run, and the hint is the story from before the module owned its tables. `AGENTS.md` already said to remove it the next time the file was touched. The 0.20.0 commits touched the file and left the probe.

**Fix:** integration tests and the test endpoint now depend only on the database being reachable. The catalogue-column probe still excludes `:requires_catalogue`. The stale `pk_dep/3` comment and the README "tables ship in core" paragraph went with it. The `AGENTS.md` TODO is removed.

### 2. BUG - MEDIUM — the published README still described managed mirrors as optional

`README.md` (shipped in the Hex package) said older cores hide **Create managed organization** and that "no higher core floor is required because this path checks API availability." `ManagedMirror.supported?/0` is gone. The section was also nested under `## License`. `AGENTS.md` still said `phoenix_kit_comments ~> 0.3` in the paragraph this release rewrote; `mix.exs` is `~> 0.5` (locked 0.6.0).

**Fix:** the README section is its own heading and matches the 3.5.0 floor. The install example is `~> 0.20`. `AGENTS.md` and the `mix.exs` comment match `~> 0.5`. `ManagedMirror`'s moduledoc no longer calls the path optional.

### 3. IMPROVEMENT - MEDIUM — the session-stack test only checked the button

The changelog's fixed item is that an account added to a session stack acts on its own authority. The new test asserted the button and did not submit. A later change that showed the button and refused the write would stay green.

**Fix:** the test searches for the first manager and submits. Creation links the company. Confirmed against the current core.

### 4. IMPROVEMENT - MEDIUM — the changelog headline overstated core 3.5

"Public pages no longer download the CRM's JavaScript" is true on 3.6.0. On 3.5.0, which the pin still admits, the extra keys are ignored and the file stays in the public bundle. The following sentence said "older cores" without naming 3.5.

**Fix:** the changelog bullet names 3.6.0 and 3.5. The bundle's header comment says the same thing. Not a version bump.

### 5. NITPICK — `ColumnConfig` swallowed a missing custom-field function in silence

`load_custom_fields/0` rescued `UndefinedFunctionError` to `[]` with no log, a leftover from when `CustomFields` might be absent. On this floor the function exists. A rename would drop custom columns and look like an empty catalog.

**Fix:** that clause is gone. Any failure is logged and still returns `[]`, so a page does not crash.

## Left as they are

- **Role subtab language.** `Tab.label` is one string, so the sidebar uses the primary-language label and only refreshes on `refresh_sidebar/0` or a restart. The Role Access list and the role page title use the viewer's language. `dev_docs/2026-11-15-brief-core-account-links-in-crm.md` asks core for a label resolved at render. No CRM-side workaround that would stay correct.
- **Optional sibling modules.** `Code.ensure_loaded?` / `apply/3` around staff, projects, the catalogue, and comments stay. Those apps are not dependencies. The removals in this range are the core-version gates (`ManagedMirror.supported?/0`, notifications `apply/3`, the column-picker guard, the i18n and chain-check excludes).
- **Direct notification call.** `InteractionNotifier.fan_out/2` calls `PhoenixKit.Notifications.fan_out_from_activity/2` and still rescues. A notify failure cannot fail the save. The function exists on 3.5.0+.
