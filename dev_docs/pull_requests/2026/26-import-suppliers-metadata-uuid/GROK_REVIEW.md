# Review: Fix raw-binary uuid leaking into company metadata on import

**PR:** [#26](https://github.com/BeamLabEU/phoenix_kit_crm/pull/26) (merged `db074dd`)
**Author:** timujinne
**Branch:** `fix/import-suppliers-metadata-uuid`

## Summary

`fetch_suppliers/2` reads catalogue rows with raw `repo.query!`, so Postgrex returns a `uuid` column as a 16-byte binary rather than text. That binary was stored in `Company.metadata["cat_supplier_uuid"]`; JSONB cannot encode a raw binary, so every row that needed a new CRM company failed on INSERT. Isolated `process_supplier_row/4` tests never saw this because they built the supplier map with `Ecto.UUID.generate()` (text).

The fix runs both `uuid` and `crm_company_uuid` through the existing `display_uuid/1` at the read boundary. Adjacent test-infra fixes were required to even execute the new `run/1` test: the catalogue-presence probe in `setup_all` and `test_helper.exs` ran with no sandbox checkout (sandbox is already `:manual` by then), so every `:requires_catalogue` test was excluded regardless of schema; `insert_supplier/3` also needed binary uuid params and `inserted_at`/`updated_at`.

The production diagnosis is correct, `display_uuid/1` is the right helper, and going through `run/1` is the right test layer. Two residual gaps.

## Findings

### BUG - MEDIUM — `test_helper.exs` catalogue probe leaks a sandbox owner on query failure

**Where:** `test/test_helper.exs`

`start_owner!` sits *inside* the `try`, and `stop_owner` sits *after* `query!` in the same `try`. A raise from `query!` (or an EXIT, which the `catch` also swallows) skips `stop_owner` and leaves a checked-out connection until the VM exits. `setup_all` in the mix-task test does this correctly (stop is outside both inner `try`s).

**Fix applied:** `try`/`after` around the query so the owner is always released. The mix-task `setup_all` was given the same `after` so a later edit cannot reorder it into the leaky shape.

### IMPROVEMENT - MEDIUM — `process_supplier_row/4` still accepted a raw-binary uuid

**Where:** `lib/mix/tasks/phoenix_kit_crm.import_suppliers_from_catalogue.ex`

The write path (`create_company_from_supplier/2` → metadata map) is `process_supplier_row/4`, which is public-for-testing and is the function every prior integration test calls. The PR only normalized at `fetch_suppliers/2`. A caller that still passes a Postgrex uuid (or a future helper that forgets `display_uuid/1`) hits the same JSONB INSERT failure.

`already_linked?/1` matching `is_binary(uuid)` also treats a 16-byte binary as "already linked" — correct for a non-null stamp, but then `company_uuid` in the result stays binary. Normalizing at the start of `process_supplier_row/4` makes every consumer of that function JSONB-safe.

**Fix applied:** `Map.replace/3` both uuid keys through `display_uuid/1` at the top of `process_supplier_row/4` (missing keys stay missing). Added an integration test that feeds a dumped 16-byte uuid through `process_supplier_row/4` and asserts `metadata["cat_supplier_uuid"]` is the canonical text form. The existing `run/1` test still covers the `fetch_suppliers/2` boundary.
