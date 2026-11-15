# Brief for phoenix_kit (core): showing account links in the CRM

**From:** phoenix_kit_crm, 2026-11-15. **Core:** 3.6.0 (the links shipped in 3.5.0, V229).
**Background:** `phoenix_kit/dev_docs/plans/2026-11-07-account-relationships.md`;
WoodMatrix's brief said "The CRM could show these relationships later." This is that.

## What the CRM wants to build

Read-only, in the CRM's own pages. Nothing is written from the CRM, and the CRM's
own `CompanyMembership` (contact ↔ company, grants no access) stays a separate fact.
The two are never synced.

- **Company page**, when the company mirrors an organization account
  (`phoenix_kit_crm_companies.user_uuid`): "People with access". Each person with
  the link's type and roles, or "Member" for the older `organization_uuid` tie. Each
  person links to their CRM contact when they have one, and the list links to core's
  People tab for changes.
- **Contact page**, when the contact mirrors a person account: "Acts for". The
  companies they are tied to, the same way round, each linked to its CRM company.

`PhoenixKit.Users.OrganizationPeople.list/1` and `PersonOrganizations.list/1`
(with `organizations_by_person/1` for the batched form) look like the right reads,
since they already cover both kinds of tie.

## What we need from core

1. **Public reads.** Confirm that `OrganizationPeople.list/1`,
   `PersonOrganizations.list/1` and `organizations_by_person/1` are a public API a
   module may depend on, with the entry shape documented: type (with its translated
   name, `RelationshipTypes.name/2`), all-roles or the role records, and link vs
   older tie. Today their moduledocs describe them as serving core's own admin page.
   If they aren't meant for modules, tell us which functions are.

2. **Who may see it.** The CRM's records are open to anyone holding the `crm`
   permission. Who can act for a company, and with which roles, is access
   information. Which check should the CRM apply before showing it? A core
   predicate such as `OrganizationPeople.visible_to?(scope)` would work. So would
   guidance, for example "requires core's `users` permission as well as `crm`".

3. **Links into core's pages.** The CRM would link to an organization's People tab
   and a person's admin page. Today the path is a private string in
   `PhoenixKitWeb.Live.Components.OrganizationPeople`
   (`"/admin/users/view/#{uuid}?tab=people"`). We'd like a public helper for each,
   built on `Routes.path/1`, so the CRM doesn't hard-code core's URLs.

4. **Live updates.** A link added, changed or removed should refresh an open CRM
   page. `ScopeNotifier` is per person and about their scope. Is there, or could
   there be, a topic per organization (and per person) announcing that its links
   changed, with the uuid only? Best-effort, sent after commit, on the host's PubSub.

## A second, smaller ask: translated labels on runtime tabs

The CRM registers one sidebar subtab per opted-in role at runtime
(`PhoenixKitCRM.SidebarBootstrap`, into `Dashboard.Registry` under
`:phoenix_kit_crm_roles`). `Tab.label` is one plain string, so since 3.5.0 the CRM
puts in the role's primary-language label (`Roles.display_name(role,
Multilang.primary_language())`). Two gaps follow:

- A viewer in another language sees the primary-language label.
- A label edited on the Roles page shows only after the CRM's next
  `refresh_sidebar/0` or a restart. The CRM has no process listening on
  `phoenix_kit:admin:roles` and doesn't want one just for this.

Either of these would close both gaps: a tab label resolved at render (per-language
labels, or a `{module, function, args}` resolver called with the viewer's
language), or the registry re-reading a role-backed tab when a role is updated.
Core's choice.

## Not asked for

- Phase 2 (`phoenix_kit_account_links`, links that grant no access). People who
  don't log in stay in the CRM.
- Any write path from the CRM into links.
