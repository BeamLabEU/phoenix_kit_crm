# PR #39 — Say the company is not set, and what an empty company or project has

- **Merge commit:** `fd2de2c` (merges `01d796d` + `58a8e80` from `mdon/main`)
- **Author:** Max Don
- **Reviewer:** Grok
- **Scope:** wording only — three user-facing strings, the three gettext catalogues, and tests that pin the new copy.

## What the PR does

Same-day owner review of the catalogue's selects, applied here:

- Contact form company select: `"— none —"` → `"— Company not set —"` (`contact_form_live.ex:638`). `"— none —"` read as if there were no companies to pick.
- Company Members empty state: `"No contacts linked to this company yet."` → `"This company has no contacts yet."` (`company_show_live.ex:676`).
- Projects Client tab empty state: `"No client linked to this project yet."` → `"Client not set."` (`project_client_live.ex:155`).

`et` / `ru` translations were rewritten to match (`määramata` / `не указан`, and the company-empty sentence without "seotud" / "привязан"). English `msgstr` stays empty, this repo's convention for strings that need no `en` override.

The three call sites are the right ones, and the two rules do not collide: an unset *value* says "not set"; an empty *collection* says what the page has. Neighbouring copy already used "set" language (`"The contacts whose Company is set to this one"`), so the Members empty title now matches its intro.

Old msgids are gone from `default.pot` and all three `.po` files — no leftover duplicates. Tests cover the rendered English on all three pages.

## Findings

### IMPROVEMENT - MEDIUM — `Client not set.` translations only ran behind the SQL sandbox

**Where:** `test/phoenix_kit_crm/web/company_show_live_test.exs`

The PR pinned all three new strings' `et` / `ru` catalogues in one table on the company-show LiveView case. That file `use`s `LiveCase`, which auto-tags `:integration`, so the translations skip when the test DB is down. Two of the three strings are not rendered on that page at all. `project_client_live_test.exs` is deliberately DB-free (it renders the template against in-memory structs) and already asserted the English `"Client not set."` — that is where the Client catalogues belong.

**Fixed:**

- `project_client_live_test.exs` now pins `Klient määramata.` / `Клиент не указан.` next to the empty-state render assertion, and the test name no longer says "link-a-client".
- `company_show_live_test.exs` keeps only `"This company has no contacts yet."`.
- Contact-form already pinned `"— Company not set —"` on the select itself.

### NITPICK — leftover `fuzzy` flag on the English Members empty-state msgid

`mix gettext.merge` marks a renamed msgid fuzzy. `et` / `ru` had new msgstrs so the flag was cleared there; `en/LC_MESSAGES/default.po` kept `#, elixir-autogen, elixir-format, fuzzy` on `"This company has no contacts yet."` with an empty msgstr.

Runtime is unchanged (empty English falls back to the msgid either way), but it is the only merge artifact this PR left, and a later extract/merge pass treats fuzzy entries as stale. Stripped. The pre-existing fuzzy on `"Settings"` is unrelated and was left alone.

### NITPICK — remaining "None" / "linked" copy deliberately left alone

These are a different meaning than the two complaints, and renaming them would make the sentences worse or change a product term:

- `company_show_live.ex:649` and `contact_show_live.ex:378` — `gettext("None")` for an unset mirror / login account. Empty-field display, not a select prompt that looks like an empty option list. Contact-show already uses a bare `—` for an unset company, which is the right empty-value glyph and is not the form prompt the owner objected to.
- Mirror flashes and errors (`"Mirror account linked"`, `"This account already has a linked company"`, …) — "linked" is the feature's verb.
- `list_form_live.ex:129` — locale prompt `"Not set"` already uses the "not set" pattern; it is an optional language, not a missing company.

Recorded so the next pass does not "finish" the reword into these.

## Framework review

Nothing in the PR touches a lifecycle path. Surrounding LiveViews were checked against the usual hazards while reading the hunks:

- `ContactFormLive` / `CompanyShowLive` load in `handle_params/3`, not `mount/3`.
- `ProjectClientLive` is the documented exception: nested `live_render` with no `handle_params/3` (the projects hub's contract), so CRM reads run on the connected mount only and the disconnected mount paints a skeleton. The empty-state string is in `render/1`; the `loading` assign still hides it on the dead render. The test that refutes `"Client not set."` when `loading: true` still holds.

No findings.

## Gate

`mix format` + `mix precommit` (compile `--warnings-as-errors` + format + credo `--strict` + dialyzer + `deps.unlock --check-unused` + `hex.audit`) — clean, after the fixes above.

`mix test` — 797 tests, 9 failures, none from this PR:

- the same seven `SchemaOwnerGuard` / `SchemaOwnerGuardWiring` tests that fail on this runner (scratch databases, `DBConnection.ConnectionError … connection not available`)
- two pre-existing PubSub-timing flakes (`CompanyShowLiveTest` "a member's new interaction refreshes the Interactions rollup", `ContactShowLiveTest` "the Files tab's interaction roll-up follows interactions changed elsewhere"). Both pass in isolation; `render(view)` sometimes races the broadcast. Not this wording change.
