# CRM feature assessment — 2026-10-16

Where `phoenix_kit_crm` (0.16.0 + unreleased party-role work, V10) stands as
a product, what comparable CRMs offer that it does not, and what to build
next. Based on the code and `AGENTS.md`; spot-checked by searching `lib/` for
deals/pipeline, tags, custom fields, export and merge (none found).

## Verdict

A strong relationship-and-interaction layer, not yet a sales CRM. It is good
at "who are our parties, what are they to us, and what happened between us".
It is thin on grouping, extensibility and follow-up, and has no sales
pipeline.

## What it does well

- **Directory.** Contacts and companies, memberships (role / department),
  soft delete, filter strips with search-independent counts, per-user column
  configuration.
- **Party roles as data (V10).** Built-in supplier / manufacturer / customer /
  partner plus admin- or host-defined roles (e.g. "Carrier"), translated names,
  badge and icon, ordering, archive / restore / delete, idempotent
  `PartyRoleTypes.ensure/3` for hosts.
- **Interactions.** One row moves planned → happened / cancelled, with start,
  end, duration and location. Parties resolve to contacts, staff or free text.
  Parties with a user account are notified of plans, moves and cancellations.
  Anchored to a contact XOR a company.
- **Project integration.** Meetings on a project feed the projects work
  ledger; the Client column on the projects list; interactions appear on the
  projects calendar and API; tasks link back through mentions.
- **Other integrations.** Staff, catalogue suppliers, comments, files and
  images (core Storage), activity feed, CRM↔user mirror with conflict
  handling.
- **Mailing lists.** CSV import, membership, consent / opt-out on contacts,
  duplicate-email and list-overlap comparison report.

## Gaps against typical CRMs

| Gap | Why it matters | Effort |
|---|---|---|
| Tags / segments | Records can only be grouped by role or by list. Free tags and saved filters are table stakes. | Small |
| Custom fields | One `metadata` map and fixed columns. Real use needs admin-defined fields ("VAT no.", "payment terms") in forms and column pickers. The party-role work already established the pattern (data table, multilang names, form). | Medium |
| Duplicate merge | The Compare report finds duplicate emails but cannot merge. A merge must move interactions, memberships and roles. | Medium |
| Export | CSV import exists; no export of contacts, companies or interactions. | Small |
| Follow-up tasks and reminders | A plan is a meeting only; nothing reminds anyone before it starts (needs a scheduled job). No "call back Tuesday". | Medium |
| Deals / pipeline | No opportunities, stages, values or won/lost. Core of a sales CRM; only matters if sales run through this module. | Large |
| Global search, saved views | Search is per index page; no cross-entity search box, no saved filters. | Small–medium |
| Email / calendar sync | Interactions are entered by hand; no inbox or calendar capture. | Large |
| Ownership | No account owner / assignee on a record and no "my records" view. | Small |
| Reporting | The overview is a directory front door; no metrics such as stale accounts or activity per owner. | Medium |

## Recommended order

1. **Tags + saved filters, and export.** Cheap; makes the CRM workable at a few
   thousand records.
2. **Custom fields.** Hosts already want to model their own business (the
   party-role request); this is the same need one level up. Reuse the
   party-role-type approach.
3. **Owner + follow-up tasks with reminders.** Turns the log into something
   people act on. Prefer reusing `phoenix_kit_projects` tasks through the
   existing mentions instead of a new table.
4. **Duplicate merge.** The Compare report already finds the candidates.
5. **Deals / pipeline.** Only if the CRM is meant to run sales. Current usage
   (suppliers, carriers, project clients) points at items 1–4 first.

## Open questions

- Is the CRM meant to run sales, or to be the party directory plus client
  history for projects and procurement? The answer decides whether item 5
  matters at all.
- Should reminders depend on a scheduled-job facility in core, or on an
  optional Oban dependency?
