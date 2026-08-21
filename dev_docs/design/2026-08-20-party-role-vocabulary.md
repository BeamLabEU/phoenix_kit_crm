# The word "role" means too many things — rename options

**Date:** 2026-08-20
**Status:** DISCUSSED, NOT DECIDED. No code changed. Parked deliberately so the
CRM ↔ catalogue integration could continue.
**Raised by:** Max, after asking how the CRM role system works and noticing it
is disconnected from login permissions.
**Related:** §C1 of `crm-integrity-review-2026-08-19.md` (Tymofii's own
recommendation to close the vocabulary before building further on it).

---

## The problem

"Role" already means four different things inside `phoenix_kit_crm` alone,
before RBAC is even considered:

| Meaning | Where | References in `lib/` |
|---|---|---|
| Commercial party role — supplier / customer / partner / manufacturer | `phoenix_kit_crm_party_roles` | **157** across 15 files |
| Which RBAC roles have CRM enabled | `phoenix_kit_crm_role_settings` | 66 |
| A saved *view configuration* — not a role at all | `phoenix_kit_crm_user_role_view` | 42 |
| A person's job title at a company | `company_memberships.role_in_company` | 19 |

Add core's RBAC `PhoenixKit.Users.Role` (Owner/Admin/User, plus custom values
like `Client` and `Partner`) and the same word covers five unrelated concepts.

It is not academic. The customer portal on the Andi host gates on the RBAC role
`Client`, which has no relationship to the CRM `customer` party role — different
table, neither writes the other. The review measured 11 `Client` role
assignments against 1 `customer` party role, describing unrelated sets of
people.

## How it got here

- **2026-07-12** — Tymofii wrote the CRM v2 design doc and the `PartyRoles`
  context on the same day. Vocabulary was supplier / **client** / partner.
- **2026-07-14** — core migration **V148** created
  `phoenix_kit_crm_party_roles`.
- **2026-07-29** — the value `client` was renamed to `customer`. This commit is
  the origin of the split: before it, the CRM value and the RBAC role at least
  matched by name.
- **2026-08-05/09** — the "Client project extension" added a third use.
- **2026-08-20** — `manufacturer` added when suppliers and manufacturers moved
  into CRM.

So the concept is about six weeks old and was authored entirely in-house, which
is why a rename is still cheap.

## What a rename would cost

Three tiers, and they are very different:

1. **UI wording only** — labels and gettext. An hour. No migration.
2. **UI + Elixir naming** — 157 mechanical references across 15 files. The
   cross-module surface barely moves: the catalogue calls eight functions and
   five are already role-free (`get_supplier`, `get_manufacturer`, and the
   batch/list variants). Only `grant_role`, `list_companies_with_role` and
   `list_contacts_with_role` carry the word, and they can stay as thin aliases
   so nothing breaks mid-rename. Roughly an afternoon.
3. **Renaming the table and column** — **expensive, and not recommended.**
   `phoenix_kit_crm_party_roles` and its `role` column appear in **59 entries of
   core's ExpectedSchema manifest**. Renaming them is a reshape of objects core
   asserts, so it drags in the excluded-object protocol (generator exclusion
   list, inventory-doc token, manifest regeneration, chain-hash restamp, core
   floor bump) *plus* a live-data rename. All for a name only developers reading
   migrations ever see.

**Recommendation: do tiers 1 and 2, never tier 3.** Leave the database table
named `phoenix_kit_crm_party_roles` with a comment explaining why it differs
from the code.

## Options considered

### Verb-led, with no container noun — RECOMMENDED

Stop naming the abstraction at all. The UI states the fact as a sentence, and
the code is verb-led:

```
Parties.grant(company, :supplier)
Parties.revoke(company, :supplier)
Parties.holds?(company, :supplier)
Parties.list(:supplier)
```

> **This company is our…**  ☑ Supplier  ☑ Manufacturer  ☐ Customer  ☐ Partner

The word "role" then appears nowhere — code, UI, or conversation — and no
replacement noun has to be agreed. In prose you say "Baltic Timber is a
supplier", which is what people say anyway. It is also the smallest of the
rename diffs, because most of the 157 references are calls that simply lose a
suffix.

### "Commercial role"

Keep the canonical term but never let the bare word stand alone: `commercial_role`
in code, "Commercial role" in the UI. Then "role" always means permissions and
"commercial role" always means this. Safest and smallest, but keeps a word we
would rather drop. The current form label already reads "Commercial roles".

### "Relationship"

Accurate — this genuinely is a relationship between the party and us — and it
collides with nothing. **Max's objection:** a relationship is between two
things, and the second side ("us", the operating company) is implicit and
unmodelled, so it reads awkwardly as a field on a single record. The sentence
framing above covers that weakness if this option is chosen.

### "Assignment" — REJECTED

Proposed as a way to imply the concept without naming it. Three problems:

- core's permission system already owns the verb: `Roles.assign_role(user, "Admin")`,
  which is exactly how a `Client` gets portal access today. "Assign them as a
  supplier" and "assign them the Client role" would both be valid sentences
  meaning different things — the same ambiguity, moved from noun to verb;
- `phoenix_kit_project_assignments` is already a table, and the catalogue uses
  the word for attribute-group assignments;
- this is Phoenix: `assign`, `assigns` and `assign_new` are in every LiveView.

It is also a mechanism word rather than a domain word — it names the act of
attaching, not the thing attached.

### "Capacity" / "partner function"

`capacity` is genuinely one-sided and precise ("acts in the capacity of
supplier") but reads like throughput. `partner function` is SAP's actual term
for this exact concept, but it is opaque to anyone outside SAP and collides
with the existing `partner` value. Both noted, neither recommended.

## The bigger question this sits inside

A rename removes the confusion; it does not remove the **two systems**. The
boss's longer-term goal is for a supplier to log in and do something — offer a
price, for instance — and today nothing derives access from a party role. The
only `has_role?` call in CRM is the form deciding which checkboxes to tick.

Half the bridge already exists: both `Company` and `Contact` carry a nullable
`user_uuid` (Tymofii's mirror work), and `get_by_user_uuid/1` resolves a login
user back to their party. What is missing is the step that turns "this party is
a supplier" into "therefore this login may do X".

The suggested split, when that gets built:

- **permissions decide which screens exist** — e.g. a `supplier_portal` module
  key, using the existing custom-key mechanism;
- **the party role plus the user link decide whose data you see** — the gate is
  *this user's linked party holds an active supplier role*, and every query is
  scoped to that party.

That keeps exactly one source of truth for "who is a supplier" and stops RBAC
acquiring a competing copy — which is the mistake already made with
`Client` / `customer`, and the one most likely to be repeated for suppliers.

Note the security consequence: once a supplier can log in, every query must be
scoped to their own party, or one supplier sees another's prices.
