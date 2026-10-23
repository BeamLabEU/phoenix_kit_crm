# Claude review — PR #24 "Use core nav_tabs for all six CRM tab strips" (2026-10-23)

Merged as `39c685b` (author mdon). Read: the six LiveView diffs
(`companies_live`, `contacts_live`, `company_show_live`, `contact_show_live`,
`lists_live`, `list_members_live`). A Grok review already exists.

## Findings

None needing a change.

- **NITPICK: `ListMembersLive` maps `@filter == nil` to the id `"all"` in the template** (`active_tab={@filter || "all"}`). Correct, but the knowledge that `nil` means "All" now lives in the template as well as in the filter logic. A string-valued filter assign would remove the special case. Left.

## Checked, clean

- **Tabs became maps** (`%{id:, label:, icon:, patch:}`) instead of positional tuples, and `valid_tabs/3` shares the same list as the strip (`& &1.id`), so the deep-link clamp and the nav cannot drift.
- **`patch` URLs stay prefixed:** `tab_path/2`, `companies_path/2`, `members_path/2` and `Paths.lists/0` all build through `Paths`/`Routes.path/1`, and `nav_tabs` passes `:patch` through verbatim; the show-page tests pin `href` values with the `/en/admin/crm/…` prefix.
- **No behaviour moved:** each strip kept its labels, order, conditional trashed tab, and patch targets; the later filter-strip rework (#32) builds on `filter_tabs/1` rather than undoing this.
