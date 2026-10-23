# Claude review — PR #9 "CRM v2 design spec: party roles (suppliers/clients) + catalogue/warehouse integration" (2026-10-23)

Merged as `39e871f` (author timujinne). Docs only: `dev_docs/design/crm_v2_parties_suppliers_clients.md`
(225 lines, dated 2026-07-12). Read against what shipped.

## Findings

- **NITPICK: the spec is a proposal frozen at 0.2.4 and several of its concrete choices did not ship as written.** The module now owns its own migration chain (V01 adopts the tables core used to create) instead of shipping DDL through core; the role vocabulary became data (V10, `phoenix_kit_crm_party_role_types`) rather than the fixed `supplier|client|partner`; "client" was later renamed to "customer". A reader following the spec literally would build the wrong table. The later design record (`2026-08-20-party-role-vocabulary.md`) and AGENTS.md are the live source. A one-line "superseded in part — see …" header would prevent the mix-up. Left: the maintainer's design record to edit.
- **Prose slip:** one Russian word ("через") sits in an English sentence in §0. Cosmetic.

## Checked, clean

- **The load-bearing decisions held up:** CRM as party master with roles on an edge table, `cat_suppliers` as a fallback with a `crm_company_uuid` cross-reference, backfill by an opt-in mix task, and soft UUIDs across optional-module boundaries are all what the code does now (`PartyRoles`, `CatalogueImport`, the soft-reference rule for `project_uuid`).
