# phoenix_kit_crm v1 — Interaction Tracker (design note)

**Status:** Agreed direction (boss-set 2026-06-25). Pre-implementation design.
**Companions:** `../research/crm_feature_landscape.md` (the ~80-platform study),
`../research/feature_inventory.md` (gap analysis).

---

## 1. Direction & why it's the right first move

The boss's first goal: make the CRM a **relationship / interaction tracker**, not a
sales-pipeline CRM (yet). v1 =

1. a **Contact** record — cloned from the staff module's "add person" form, *minus* the
   structured department/team system (that becomes a single free-form `company` field), and
2. an **Interactions / History tab** on the contact where staff log "client called, we
   discussed XYZ, involved parties were A, B, C."

This is not a compromise — it's the model the research pointed at. The whole study's #1
conclusion was *the object model is easy; the differentiated value is the interaction +
relationship graph.* Starting at Contact + interaction log + a loose party graph builds the
genuine spine (the "automatic/relationship CRM" model: Affinity / Folk / Nimble), with
Deals/Pipeline layering on later. It maps onto the **Option C hybrid** plan: hand-build the
small opinionated core, reuse the ecosystem for the rest.

### Decision: data in CRM-owned tables; the user link is opt-in (staff-style)
We considered a **user-system-centric** model (Contact = `User` with `account_type="person"`,
Company = `User` with `account_type="organization"`, link via core `organization_uuid`, extras
in `custom_fields`) to maximize what's stored in the core user system. **Rejected** (boss
call, 2026-06-25): it would fill `phoenix_kit_users` with people who will never authenticate.
**Decision:** all contact/company data lives in **CRM-owned tables** (this doc); a contact is
connected to a core `User` **only when the opt-in checkbox is ticked** (default off) — exactly
the staff `find_or_create_user_by_email` flow, made optional (§3.3). This keeps the users
table to actual login users while still allowing any contact to be promoted to one.

---

## 2. Scope

**In (v1):**
- `Contact` schema + admin list / form / show (clone staff Person patterns).
- `Company` schema (a first-class record) + a **contact↔company link** carrying free-form
  `role_in_company` and `department` (replaces the dept/team system).
- `Interaction` schema + an **Interactions/History tab** on the contact show page: a
  timeline + an add/edit form.
- **Involved parties** field — free-form input that **searches CRM contacts** and (if the
  staff module is enabled) **staff people**, resolving matches to real links while keeping
  unmatched text as-is.
- Reverse view: a contact's History shows interactions where they're the **subject** *or* a
  **party**.
- **Optional login connection** — a checkbox to connect a contact to a PhoenixKit user so they
  can sign in (§3.3); default off.
- Soft-delete, activity logging, i18n — following the staff module conventions.

**Out (deferred, easy follow-ups — clone staff components later):**
- Avatar / Files / Images media tabs, Comments tab on the contact.
- Deals / Pipeline / Leads / forecasting (the sales-CRM layer).
- Per-party **roles** on interactions, and durable **relationship-roles** (decision-maker /
  spouse) — see §4; these go on a *future relationship edge*, never on the interaction.
- Linking a contact to a **staff `Person`** (the optional **user** link is in v1 — §3.3 — but
  a "this contact *is* staff member X" link is deferred until a feature needs it).
- A "send invite / magic-link" action on connect (§3.3) — easy follow-up.
- The existing **Organizations** view (users where `account_type="organization"`) stays as-is
  for now; it's orthogonal to the new Contact object. Revisit once Contacts lands.

---

## 3. The Contact — cloned from staff `Person`, with ONE critical change

Clone the *shape* of `PhoenixKitStaff.Schemas.Person` (name, email, phones, notes, status,
`metadata`/`translations` JSONB, the soft-delete-via-`status` convention). **The one
critical adaptation:** staff `Person` **requires** a 1:1 `user_uuid` (staff are internal
login users). **CRM contacts must NOT** — clients/customers are generally not login users.
So `Contact` drops the required user link entirely.

`phoenix_kit_crm_contacts`
| Column | Type | Notes |
|---|---|---|
| `uuid` | UUIDv7 PK | |
| `name` | string | display name (like staff `Person.name`) |
| `status` | string, default `"active"` | `active`/`inactive` + `"trashed"` sentinel (soft-delete) |
| `email` | string | optional |
| `phone` | string | optional |
| `notes` | text | optional |
| `user_uuid` | UUIDv7 FK → `User`, **nullable**, unique-when-set | optional login link (§3.3). NULL = no login (default) |
| `metadata` | JSONB `{}` | mirrors staff (avatar pointer etc. later) |
| `translations` | JSONB `{}` | optional; can defer (clients rarely need multilang) |
| timestamps | utc_datetime | |

- **Soft-delete:** `status="trashed"` + `metadata["trashed_from_status"]` stash — the
  workspace convention (same as staff). `list_contacts/1` excludes trashed by default.
- No required FKs (drop staff's `user_uuid`/`primary_department_uuid`). Optional links to a
  User / staff Person are a later, additive change.
- **No `job_title` / `company` on the Contact** — both move to the contact↔company link
  (§3.2): a contact can work at >1 company with a different role/department at each, so those
  are facts about the *link*, not the person.

### 3.1 `Company` — a first-class record (clone the Contact pattern)
`phoenix_kit_crm_companies`
| Column | Type | Notes |
|---|---|---|
| `uuid` | UUIDv7 PK | |
| `name` | string | the company name |
| `status` | string, default `"active"` | `active`/`inactive` + `"trashed"` (soft-delete) |
| `website` | string | optional |
| `email` | string | optional |
| `phone` | string | optional |
| `address` | text | optional (free-form for v1; structured later) |
| `industry` | string | optional, free-form |
| `notes` | text | optional |
| `metadata` | JSONB `{}` | |
| timestamps | utc_datetime | |

Same conventions as `Contact` (soft-delete, no required FKs). Gets its own admin
list/form/show. Company-level interaction rollup ("everyone we've talked to at Acme") is a
natural follow-up via the link, not v1.

### 3.2 Contact ↔ Company link — many-to-many, role + dept on the edge
A join table so a contact can relate to several companies, **presented as one
company+role+department block** in the v1 contact form (exactly how staff renders one team
via its `TeamMembership` join). Role and department are **free-form** (the boss's
"role in company" + "department/team/whatever").

`phoenix_kit_crm_company_memberships`
| Column | Type | Notes |
|---|---|---|
| `uuid` | UUIDv7 PK | |
| `contact_uuid` | FK → `crm_contacts` | `ON DELETE CASCADE` |
| `company_uuid` | FK → `crm_companies` | `ON DELETE CASCADE` |
| `role_in_company` | string | **free-form** — e.g. "CEO", "Procurement Lead" |
| `department` | string | **free-form** — "department/team/whatever" |
| `is_primary` | boolean, default `false` | which company is the contact's main one (for display + snapshot) |
| `position` | integer | order when a contact has several |
| timestamps | | |

- A contact with **no** company link is fine (an individual / freelance client).
- The **primary** membership drives the contact's headline "Company · Role" display and is
  what the interaction `party_snapshot` (§4.2.1) captures.

### 3.3 Optional connection to the user system (checkbox) — let a contact log in
Boss requirement: a contact can *optionally* be connected to a real PhoenixKit login user, so
an added person can sign in. **Controlled by a checkbox** on the contact form (e.g. *"Allow
this person to log in"*). This is staff's user-link pattern, made **optional** (staff requires
it; CRM defaults to OFF).

- **Storage:** the nullable `crm_contacts.user_uuid` FK (§3). NULL = no login (default);
  set = connected. A **partial unique index** (`WHERE user_uuid IS NOT NULL`) keeps it 1:1 —
  one contact per user — while allowing many NULLs.
- **On save, when the box is checked** (clone staff's flow into a `PhoenixKitCRM` context):
  1. `email` becomes **required** (no login without one).
  2. `find_or_create_user_by_email(email)` — existing user → link it; none → register a
     **placeholder** (random password, unconfirmed, `custom_fields.source = "crm_contact"` —
     our own tag, not staff's).
  3. store `user.uuid` on the contact; **roll back a just-created placeholder** if the contact
     insert fails (staff's `create_person_or_rollback`).
- **Unchecking later → unlink only** (`user_uuid = NULL`). **Never delete the user** — it may
  be a real account; we only sever the contact's reference.
- **What they get:** the full core user system — email/password + **magic-link** + **OAuth**
  login, confirmation, roles, `custom_fields`. Core assigns the standard **User** role (Owner
  only to the very first user). Actual first sign-in is via the normal magic-link / password-
  reset flow (the placeholder has no usable password) — connecting just creates+links the
  account. *(An explicit "send invite / magic-link" button is an easy follow-up, not v1.)*
- **CRM access stays governed by the existing role opt-in** — a connected *client* is just a
  `User`; they don't get admin CRM access unless their role is opted in. (Good fit for a future
  client-portal; out of scope now.)
- **DRY note / extraction candidate:** staff's `find_or_create_user_by_email` /
  `create_person_with_user` / `rename_placeholder_email` / `placeholder?` are private + tagged
  `"staff_placeholder"`. v1 **clones** the small helper into CRM (tag `"crm_contact"`). This is
  a clean candidate to later **extract a generic core helper**
  (`PhoenixKit.Users.Auth.find_or_create_placeholder(email, source)`) — *generally applicable*
  to any module wanting optional login for a record (per the workspace "extract by general
  applicability" rule). Not a v1 blocker.

---

## 4. The Interaction + involved parties (the core of v1)

### 4.1 `Interaction` — a NEW schema (not `comments`, not core `Activity`)
Decision (confirmed): interactions are **structured log entries** (type + when + body +
parties), unlike `phoenix_kit_comments` (threaded discussion) or core `PhoenixKit.Activity`
(system audit). So a dedicated schema.

`phoenix_kit_crm_interactions`
| Column | Type | Notes |
|---|---|---|
| `uuid` | UUIDv7 PK | |
| `contact_uuid` | FK → `crm_contacts` | **the subject** — whose History tab this is. `ON DELETE CASCADE` |
| `interaction_type` | string | `call`/`email`/`meeting`/`note`/`other`, default `note` |
| `occurred_at` | utc_datetime | when it happened (defaults to now, editable) |
| `subject` | string | optional short title |
| `body` | text | "discussed XYZ" |
| `owner_user_uuid` | UUIDv7, nullable | the staff user who logged/handled it (the *internal* side — soft ref to `User`) |
| `metadata` | JSONB `{}` | |
| timestamps | | |

### 4.2 Involved parties — flat, resolvable list, NO per-party role
**Research verdict (2 independent agents, fully corroborated):** mature CRMs keep two
concepts on separate tables, and conflating them is the trap —
- **Interaction participation-type** (sender/recipient/organizer/attendee) — channel-shaped,
  only Dynamics `ActivityParty` models it, auto-derived; *not* a business role.
- **Durable relationship-role** (decision-maker / spouse / opposing-counsel) — lives on the
  **contact↔company/deal edge**, never on the activity (Salesforce `OpportunityContactRole`,
  HubSpot association labels, LACRM "Relationships" tool).

Every lean/relationship CRM (Pipedrive, Affinity, Folk, Nimble, Streak, Capsule, Less
Annoying) uses a **flat participant list with no per-party role**. Putting a role on each
interaction party duplicates a durable fact onto an ephemeral one and makes "who's the
decision-maker?" an un-queryable aggregation over activities.

→ **v1: just "who was involved." No labels.** Storage = the Notion `@mention` /
entity-resolution pattern: each party is an **optionally-resolved mention** with a
`raw_name` fallback always kept, so a free-text name is first-class and **promotable to a
real contact later** without rewriting history.

`phoenix_kit_crm_interaction_parties`
| Column | Type | Notes |
|---|---|---|
| `uuid` | UUIDv7 PK | |
| `interaction_uuid` | FK → `crm_interactions` | `ON DELETE CASCADE` |
| `raw_name` | string, **required** | the typed text / display fallback — ALWAYS kept |
| `contact_uuid` | FK → `crm_contacts`, nullable | set when resolved to a CRM contact; `ON DELETE SET NULL` (degrades to `raw_name`) |
| `staff_person_uuid` | UUIDv7, nullable | **soft ref** to `staff_people` (no DB FK — keeps staff optional, mirrors `staff.work_location → locations`); resolved at app layer |
| `party_snapshot` | JSONB `{}` | **as-of-then profile snapshot** — auto-captured at log time (see 4.2.1) |
| `position` | integer | preserve display order |
| timestamps | | |

- **Exclusive-arc invariant:** at most one of `contact_uuid` / `staff_person_uuid` is set;
  `raw_name` is always present. (DB `CHECK` for the at-most-one; app enforces too.)
- **The payoff (why resolve at all):** the resolved FKs make **"show every interaction
  involving Contact X / staff person Y"** a real query — the relationship-graph seed the
  research said is *cheap now, expensive to retrofit*.

#### 4.2.1 `party_snapshot` — capture the party's profile "as it was then"
Three different "role-like" concepts; we handle each in its correct place:

| Concept | Example | v1 decision | Where it lives |
|---|---|---|---|
| **Auto-captured profile snapshot** | "John was an *Intern* when he handled this" | ✅ **v1 — this column** | `party_snapshot` JSONB on the party row |
| **Hand-authored business relationship-role** | "Mary is the *decision-maker* for Acme" | ❌ defer | a future `crm_contact_relationships` edge (additive) |
| **Channel participation-type** | sender / cc / organizer / attendee | ⏭ skip | (only matters for email/meeting thread reconstruction) |

The snapshot is **not** a hand-typed role — it's **gathered automatically from the resolved
profile at the moment the party is added**, freezing what's relevant about them at that time.
This gives temporal accuracy: the resolved FK always points at the *live* record (current
title), but the snapshot preserves the *historical* truth, and survives even if the staff
person / contact is later edited or deleted (it complements `raw_name`).

- **What to capture** (whatever the source profile has): `name`, plus — for a **CRM
  contact** — `company` / `role_in_company` / `department` read off their **primary company
  membership** (§3.2); for a **staff person** — `job_title` / `employment_type` /
  `department` off the staff profile; plus `source` (`crm_contact`/`staff`/`free_text`) and
  `captured_at`. JSONB (not a `role` string) because the relevant fields differ by source.
- **When:** stamped when the party is resolved/saved. A free-text party gets just
  `%{source: "free_text"}` (its `raw_name` is the whole story).
- **Mirrors staff:** the staff `Employment` span already snapshots `primary_team_uuid` "as a
  history snapshot" — same temporal-denormalization pattern, applied to interaction parties.
- **Future precision (noted, not v1):** staff now has **employment history** (`Employment`,
  core V136), so for a staff party we *could* resolve the employment span active at the
  interaction's `occurred_at` for true time-travel accuracy. v1 captures the **current**
  profile at save time — a good-enough proxy for promptly-logged interactions, and the only
  option that also works for CRM contacts (which have no history table yet).

### 4.3 "Interactions involving a contact" (reverse query)
On a contact's History, show interactions where the contact is **the subject**
(`interactions.contact_uuid = X`) **OR a party** (`interaction_parties.contact_uuid = X`),
unioned + de-duped + ordered by `occurred_at`. Same shape for a staff person via the soft
`staff_person_uuid`.

---

## 5. The parties picker (UX) — clone the staff skills picker
The staff **skills picker** is the perfect reference: a *type-to-search multi-select, staged
until save*, with `phx-window-focus` re-query. For involved parties:
- Type a name → live search **CRM contacts** (name/email), then **staff people** *iff*
  `PhoenixKitStaff.enabled?` (soft dep, `Code.ensure_loaded?` + `function_exported?` guard,
  graceful degradation — exactly how staff guards `locations`).
- A match → staged as a resolved party (chip shows name + a "contact"/"staff" badge).
- No match → "use as free text" → staged with `raw_name` only.
- Staged list reconciles to `crm_interaction_parties` on **save** (like skills' `sync_*`).

---

## 6. Reuse map (clone vs. reuse)
| Need | Source |
|---|---|
| Contact list / form / show scaffolding | clone staff `PeopleLive` / `PersonFormLive` / `PersonShowLive` |
| Parties type-ahead picker | clone staff **skills picker** pattern |
| Soft-delete (`status="trashed"` + metadata stash) | staff convention |
| Activity logging | `PhoenixKitCRM.Activity` wrapper at the LV layer (clone `PhoenixKitStaff.Activity`) |
| Optional staff search source | `PhoenixKitStaff` soft dep (guarded) |
| i18n | module `PhoenixKitCRM.Gettext` (domain) + core (generics) |
| Later: avatar/media/comments tabs | clone staff components (deferred) |

---

## 7. Build sequence
1. **Core migration** (next available `VNN` — confirm number against core at build time;
   latest is V136): create the **5 tables** — `phoenix_kit_crm_contacts`,
   `phoenix_kit_crm_companies`, `phoenix_kit_crm_company_memberships`,
   `phoenix_kit_crm_interactions`, `phoenix_kit_crm_interaction_parties`. *(Local only; the
   release is boss-gated — see §8.)*
2. **Schemas + contexts** — `Contact` + `Company` + `CompanyMembership` (+ `Contacts` /
   `Companies` contexts, soft-delete, changesets, membership reconciliation), `Interaction` +
   `InteractionParty` (+ `Interactions` context with party reconciliation + snapshot capture),
   `PhoenixKitCRM.Activity` wrapper.
3. **Companies admin** — list / form / show (clone the Contact scaffolding).
4. **Contacts admin** — list (kebab actions, trash filter), form: a company+role+department
   block via a company picker + the **"allow login" checkbox** (§3.3, default off; when ticked,
   email required + find-or-create-link the user); show page Overview (headline "Company · Role"
   from the primary membership).
5. **Interactions tab** — a LiveComponent on the contact show page (clone the staff
   Events/Employment component shape): timeline + add/edit form + the parties picker
   (snapshot stamped on save).
6. **Reverse "involving" query** + the staff-search source wiring (guarded).
7. **Module wiring** — add **Contacts** + **Companies** subtabs to `admin_tabs/0`; keep settings.
8. **Tests** — schema/changeset (incl. party exclusive-arc, membership reconcile),
   context (party reconcile + resolve/free-text + snapshot + reverse query), LV smoke
   (contact+company form save, company picker, parties picker resolve, History render).

---

## 8. Migration / release logistics (important)
Like every module, CRM's tables live in **core migrations** (the existing two CRM tables are
core **V105**). So the five v1 tables need a **new core migration** → the build is a
**core-PR + crm-module pair**. Develop/test locally via `PHOENIX_KIT_PATH=../phoenix_kit`
(or through `phoenix_kit_parent`). **The actual core release + version cut is the boss's
call** — agents stop at the PR at the current version (no `@version`/CHANGELOG bump). Express
the crm module's dep on the new core as a floating `~> minimum`.

---

## 8b. Timezone handling (interaction `occurred_at`)
- **Storage is always true UTC** (`timestamptz`). Never store a local wall-clock
  time in the column — that makes the stored instant ambiguous/wrong.
- **The UI uses the viewer's profile timezone**, resolved by
  `InteractionHelpers.viewer_tz/1` (per-user `user_timezone` → system
  `time_zone` setting → `"0"`/UTC — core's rule, tolerant of a partial user
  map). The value is an IANA id (`Europe/Tallinn`) or a legacy fixed offset
  (`"2"`), never a number; the show LiveViews pass it as `tz` to the
  interactions and events components.
- **Round-trip:** every conversion goes through core's per-instant helpers,
  so a named zone follows daylight saving on the date typed: the "When"
  `datetime-local` prefills with `format_datetime_local/2` (the user's local
  now); on save the entered local value is read with `parse_datetime_local/2`
  (`local_to_utc/2`; an unreadable value is a save error, never a silent
  "now"); the timeline shows stored UTC with `shift_to_offset/2`
  (`format_local/2`). Turning the value into one number and adding it — what
  the first version did — read every IANA id as 0.
- **Conflict policy (profile vs browser):** the **profile timezone wins** — it's
  the single authoritative source, consistent with how the rest of PhoenixKit
  formats dates. The browser's timezone is not used. (An earlier prototype used a
  browser JS hook; it was removed because it stored local-as-UTC and couldn't
  reconcile a profile≠browser mismatch.)
- A user who hasn't set a timezone resolves to UTC (platform-wide behavior);
  setting `user_timezone` in their profile fixes all date displays, this one included.

## 9. Open questions / decisions to confirm
1. **Contact identity fields:** is a single `name` enough (matching staff), or do we want
   `first_name`/`last_name`? (Staff deliberately chose single `name`; recommend matching it.)
2. **`translations` on Contact** — include now or defer? (Recommend defer; clients' notes
   rarely need multilang — keep `metadata`, drop `translations` for v1.)
3. **Interaction `owner_user_uuid`** — auto-set to the logging user, editable, or omit for
   v1? (Recommend auto-set to current user, not editable in v1.)
4. **Should the subject contact auto-appear as a party** in the picker, or stay implicit?
   (Recommend implicit — the tab already scopes to them; parties = *other* people.)
5. **Contact↔Company: M:N or 1:1?** (Recommend the M:N membership table presented as one
   block — simple now, no reshape if a contact later needs multiple companies. Drop to a
   plain `company_uuid` + `role`/`dept` on `Contact` only if you're certain it's always 1:1.)
6. **Company-level interactions** (log an interaction whose subject is a Company, and roll up
   "all interactions with people at Acme") — deferred to a follow-up; v1 interactions are
   contact-subject only.
