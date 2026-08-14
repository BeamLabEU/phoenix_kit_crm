# PR #22 Review — Manual two-way CRM ↔ system-user mirror (module-owned migrations)

**Author:** Tymofii Shapovalov (timujinne)
**Reviewed:** 2026-08-14 (ecosystem sweep)
**Verdict:** APPROVED — merged; no post-merge fixes required

---

## Scope

Large PR (5177 additions) doing two things: a manual, two-way mirror between CRM records
and system users, and the adoption of **module-owned migrations** via `migration_module/0`.

---

## The migration ownership question — the part that needed checking

The umbrella `AGENTS.md` is explicit that adding a `migration_module/0` is where modules
get this wrong: core's migrations run *before* module migrations in the same task, so if
core also ships a table, core wins on every host and the module's `up/1` is dead code that
drifts — while its `down/1` can still drop a table core owns.

This PR does it correctly, following the `phoenix_kit_legal` precedent:

- **V01 adopts** the 10 `phoenix_kit_crm_*` tables the core chain historically creates,
  with `CREATE TABLE IF NOT EXISTS` — a presence check only, shape-identical, a no-op on
  every existing install.
- **`down/1` never drops a table.** There is a committed test asserting the generated
  statements contain no `DROP TABLE` or `TRUNCATE`, which is the right way to pin that —
  it survives someone later adding a table to the list.
- Version tracked by a `crm_schema:1` `COMMENT ON TABLE` marker, matching the chain's own
  idiom rather than inventing a new one.
- Prefix handling is validated: there is a test rejecting injection attempts
  (`public."; DROP TABLE x; --`, `1st`, `a-b`, `""`, `bad;drop`), which is exactly the
  hazard core's prefix-safety rules exist for.

### The genuinely new object, and how core reacts to it

`phoenix_kit_crm_companies.user_uuid` (FK → `phoenix_kit_users(uuid)` `ON DELETE SET
NULL`) plus a **partial** unique index. Verified against the migrated test database:

```
user_uuid | YES        (nullable)
CREATE UNIQUE INDEX idx_crm_companies_user_uuid
  ON public.phoenix_kit_crm_companies USING btree (user_uuid)
  WHERE (user_uuid IS NOT NULL)
```

The partial predicate is the right call and easy to get wrong: without it, a plain unique
index would allow only ONE unlinked company (since NULLs would collide under some
formulations) or, more subtly, invite someone to "fix" it later. As written, any number of
companies may be unlinked while a linked user maps to at most one company.

**A column added to a core-owned table is safe here**, which I checked rather than
assumed: core's `Repair.add_extra_column_findings/3` reports a column that is not in the
manifest as an **`:info`-level `extra_object`** finding on a known table, and repair takes
no action on it. So `mix phoenix_kit.repair` will mention `column:phoenix_kit_crm_companies.user_uuid`
and will *not* drop it. Worth knowing before the first host runs repair after upgrading.

---

## The mirror itself

The design decisions that matter are all the conservative ones:

- **`user_uuid` is never cast from form params** on either schema — only via a dedicated
  `link_user_changeset/2`. That security invariant already existed on `Contact` and is
  correctly preserved on `Company` rather than quietly relaxed for convenience.
- **Nothing is automatic** — no PubSub, no background sync. The form you act from is the
  master, and a diverging field raises a per-field conflict modal instead of silently
  overwriting. For a two-way mirror this is the right default; automatic reconciliation
  is where this class of feature usually goes wrong.
- **`resolve` recomputes `diff/2` fresh at submit time**, so a stale selection or an
  out-of-band edit between opening the modal and submitting it cannot drive a bad write.
- **Conflict-modal radios are controlled** (`@choices` + `phx-change`) rather than relying
  on DOM state surviving a re-render.
- **All two-record writes go through `apply_mirror_resolution/3` inside one
  `repo().transaction/1`**, so a half-applied mirror is not representable.
- Company links are gated to organization-users and contact links to person-users —
  symmetric allowlists rather than one-sided validation.

The author states each stateful-bug-class guard test was verified to fail when its fix is
reverted. I spot-checked the shape of those tests rather than re-running each reversion;
the pattern is right.

---

## Findings

**No blockers, and no post-merge fixes were required.** `mix precommit` exits 0 and the
suite is green as merged — the second repo in this sweep where that was true.

### NITPICK — the PR does two separable jobs

Module-owned migrations and the mirror feature are independent, and the migration adoption
is the higher-risk half. Splitting them would have let the adoption land and bake on its
own. Not worth unpicking after the fact, and the migration half is well covered.

### Note for the follow-up the PR anticipates

The stated intent is that these 10 tables are *later removed from the core chain* so this
module genuinely owns them. Until that happens, both chains create them and core wins —
which is fine and is what the `IF NOT EXISTS` adoption is for, but it does mean the module
DDL is currently unexercised on any real host. When core does drop them, this migration
becomes load-bearing for the first time and deserves a fresh look at that point.

---

## Verification

- `mix precommit` → exit 0.
- `mix test` → **586 tests, 0 failures** (9 excluded), including
  `migrations_test.exs` at 17/0.
- Migration state confirmed directly against `phoenix_kit_crm_test`: marker `crm_schema:1`,
  `user_uuid` present and nullable, partial unique index as specified.
- Dependencies: `phoenix_kit` 2.3.0 → 2.4.0, `phoenix_kit_comments` 0.4.0 (unchanged).
  Nothing here uses core's new `put_slug/3`, so the `~> 2.0` pin is unchanged.
