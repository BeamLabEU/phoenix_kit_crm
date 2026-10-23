# Claude review — PR #45 "Configure the Orders tab bridge; neutral host-application wording" (2026-10-23)

Merged as `9dc000e` (`docs/neutral-host-examples`, author timujinne). Read: the
whole diff — `ContactShowLive` (bridge resolution, `load_contact_orders/3`, the
Orders tab template), the three comment-only edits, `.dialyzer_ignore.exs`,
the new `configured orders bridge` tests, AGENTS.md, the CHANGELOG entry.
Not re-read: the test-data renames (`company_api_test`, `project_columns_test`,
…), the edited PR #17 review text.

## Findings

- **BUG - MEDIUM: a malformed row from the bridge crashed the whole contact page.** The `rescue` in `load_contact_orders/3` covers the `orders_for_contact/1` call only. The template then reads `order.path`, `order.number` and `Calendar.strftime(order.inserted_at, …)` straight off every row, so one row without `:path`, with a `nil` `:inserted_at`, or a bridge that returns a map/`nil` instead of a list raised a `KeyError`/`FunctionClauseError` *in render* — the LiveView dies and every other tab goes with it. The changelog says so out loud ("a bridge that returns something other than such a list breaks the tab's render"); with the bridge now host-supplied config rather than one known in-house module, that is a sharp edge to leave. **Fixed:** the rows are checked in `load_contact_orders/3` (`valid_order?/1`: integer/binary `:number`, binary `:path`, `DateTime`/`NaiveDateTime`/`Date` `:inserted_at`). Invalid rows are skipped with one `Logger.warning` naming the count; a non-list answer logs and yields `[]`. Two new tests (a mixed good/bad list renders the good row; a non-list leaves the empty state). **For the release commit:** the CHANGELOG sentence "a bridge that returns something other than such a list breaks the tab's render" is no longer true and should be dropped (CHANGELOG is the maintainer's, left untouched here).
- **NITPICK: the upgrade is silent for existing hosts.** Before this PR the tab appeared by itself wherever the host app defined `Andi.CRMBridge`; now it vanishes until `config :phoenix_kit_crm, orders_bridge:` is set. The changelog's **Upgrading** note covers it, and it is a deliberate trade for removing a host-specific module name from a library. No warning is logged when a *configured* module is not loadable (the tab just hides). Left — a boot-time log line would be the place if a host ever reports it.
- **NITPICK: `CHANGELOG.md:698` still names `Andi.CRMBridge`** (an old 0.x entry). History, not wording to rewrite; left.

## Checked, clean

- **Runtime, not compile-time, config.** `Application.get_env/2` is read per call, so a host's `config/runtime.exs` works and no recompile of the dep is needed. `is_atom(mod) and not is_nil(mod) and Code.ensure_loaded?(mod) and function_exported?/3`, rescued, handles `nil`, a non-atom, an unloadable module and a module without the function (tests cover the unloadable one).
- **Dialyzer.** The `:unknown_function` ignore for `Andi.CRMBridge` is rightly removed: a dynamic `mod.orders_for_contact(…)` call has no static target, so no entry is needed (the gate below confirms).
- **No query in `mount/3`.** Orders load in `handle_params/3` and only on the Orders tab; other tab switches do not call the host.
- **Row link.** `path` comes from host config, never from user input, and goes through `row_link navigate=` — no open-redirect surface.
- **Tests restore the env** with `on_exit` (and the LiveCase default is non-async, so the global `put_env` cannot leak into a concurrent module).
- **Wording-only files** (`companies.ex`, `company_show_live.ex`, `mirror_panel.ex`, design doc, #17 review) change comments/docs only.
