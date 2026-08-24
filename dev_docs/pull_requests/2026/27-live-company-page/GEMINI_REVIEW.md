# PR #27 — Gemini review

**Reviewer**: Gemini (Antigravity `agy`, default model)
**Scope**: Full lib/ diff
**Date**: 2026-08-24
**Method**: Diff inlined; concrete defects only

Verbatim output; every claim was re-verified against the code before acting — see `FOLLOW_UP.md` for the verdict on each.

---

### Defect 1

* **File + Function:** `PhoenixKitCRM.Web.ContactFormLive.assign_new_form/2`
* **What breaks:** Runtime `ArgumentError` crash.
* **Scenario:** Operator clicks "New contact for this company" navigating to `/contacts/new?company_uuid=<uuid>`. `Enum.find_value(companies, &(&1.uuid == uuid and uuid))` evaluates `true and "<uuid>"`. In Elixir, `and` requires a boolean right operand; passing a binary string raises `ArgumentError`.
* **One-line fix:** Replace `&(&1.uuid == uuid and uuid)` with `&(&1.uuid == uuid && uuid)` (or `&if(&1.uuid == uuid, do: uuid)`).

---

### Defect 2

* **File + Function:** `PhoenixKitCRM.Web.CompanyShowLive.handle_info/2` (`:catalogue_data_changed` clause)
* **What breaks:** `KeyError` crash on receiving catalogue PubSub events.
* **Scenario:** A catalogue broadcast `{:catalogue_data_changed, kind, _uuid, _}` arrives. The handler accesses `socket.assigns.catalogue_enabled`, but `mount/3` and `subscribe_live/3` define the assign as `:subscribed_catalogue` (and never assign `:catalogue_enabled` to `socket.assigns`), raising `KeyError: key :catalogue_enabled not found`.
* **One-line fix:** Change `if socket.assigns.catalogue_enabled` to `if socket.assigns.subscribed_catalogue`.

---

### Defect 3

* **File + Function:** `PhoenixKitCRM.Web.CompanyInteractionsComponent.update/2`
* **What breaks:** Stale interactions rollup (fails to load new member interactions or drop removed member interactions).
* **Scenario:** A contact joins or leaves while the user is on another tab (e.g., Members). `refresh_open_tab/1` skips `send_update` because `socket.assigns.tab != "interactions"`. When the operator subsequently switches to the Interactions tab, `loaded_company_uuid == company_uuid` and `loaded_token == token` (`nil == nil`), skipping data fetch.
* **One-line fix:** Track and compare the roster state/fingerprint (or `socket.assigns.members`) in `update/2` in addition to `refresh_token`.

---

### Defect 4

* **File + Function:** `PhoenixKitCRM.Web.MediaComponent.update/2` / `PhoenixKitCRM.Web.ContactShowLive.handle_params/3`
* **What breaks:** Stale interaction attachments rollup on the Contact Files tab.
* **Scenario:** An interaction with attachments is created/updated/deleted while viewing another tab (e.g. Interactions). No `send_update` is dispatched to `MediaComponent`. When navigating to the Files tab, `loaded_key` matches and `loaded_token == refresh_token` (`nil == nil`), causing `cond` to hit `true -> {:ok, socket}` and bypass `rollup_files/3`.
* **One-line fix:** In `ContactShowLive.handle_params/3`, dispatch `send_update` with a new `refresh_token` when switching into the `"files"` tab.
