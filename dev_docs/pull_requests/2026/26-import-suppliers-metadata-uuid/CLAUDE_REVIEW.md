# Claude review — PR #26 "Fix raw-binary uuid leaking into company metadata on import" (2026-10-23)

Merged as `db074dd` (author timujinne). Read: the mix task's `fetch_suppliers`
mapping, the integration test through the real read path, and the sandbox
ownership fix in the test helper. A Grok review already exists. The code this
touched now lives in `PhoenixKitCRM.CatalogueImport` (`display_uuid/1`,
`dump_uuid/1`), so it was re-read there.

## Findings

None needing a change.

- **NITPICK: the `start_owner!`/`stop_owner` pair in `test_helper.exs` (and the matching block in the integration test's setup) leaks the owner if the query raises** — `stop_owner` is skipped on the `rescue`/`catch` path. Harmless (the owner dies with the test-helper / setup process) and the surrounding code already treats any failure as "catalogue not available". Left.

## Checked, clean

- **Root cause is right.** `repo.query!` returns a `uuid` column as the 16-byte binary (no Ecto casting), and that binary reached a `jsonb` `metadata` map, which cannot be encoded. Normalising on the read side with `display_uuid/1` fixes it for both `uuid` and `crm_company_uuid`.
- **Read and write sides are symmetric today:** `display_uuid/1` accepts nil / 16-byte raw / text; `dump_uuid/1` is its mirror on the stamp UPDATE; `CatalogueImport` also re-normalises caller-supplied rows, so a hand-built row cannot reintroduce the bug.
- **The new test goes through `run/1` → `fetch_suppliers`**, the only path that produced raw binaries — the earlier tests built text-uuid rows by hand and could never have caught it.
