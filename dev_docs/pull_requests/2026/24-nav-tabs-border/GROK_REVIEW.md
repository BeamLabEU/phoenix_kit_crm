# Review: Use core nav_tabs for all six CRM tab strips

**PR:** [#24](https://github.com/BeamLabEU/phoenix_kit_crm/pull/24) (merged `39c685b`)
**Author:** mdon
**Branch:** `fix/nav-tabs-border`

## Summary

Replaces six hand-rolled `tabs-border` strips with core's `<.nav_tabs variant={:border}>`:

- Contact and company show pages: tuple `tab_defs` become maps (`:id` / `:label` / `:icon`); a uuid-free list still feeds `valid_tabs/3`; `nav_tab_defs/4` attaches `:patch` URLs from the existing `tab_path/2`.
- Contacts / companies / lists / list-members filter strips: same component, URLs from the pages' existing Paths-based builders.

Companion to core [#746](https://github.com/BeamLabEU/phoenix_kit/pull/746) (released as phoenix_kit 2.13.6). `:patch` is passed verbatim because those URLs are already prefixed; running them through `Routes.path/1` a second time was the 2.13.5 double-prefix. Verified against the core component: `variant={:border}` is in the attr allow-list, `:patch` does not go through `Routes.path/1`, and `use PhoenixKitWeb, :live_view` imports `nav_tabs/1`. List-members correctly maps `@filter == nil` to `active_tab="all"` because nav_tabs compares string ids.

The migration itself is faithful. The gap is that none of the six strips had a test locking the new markup, the conditional Trashed tab, or the nil→`"all"` mapping.

## Findings

### IMPROVEMENT - MEDIUM — no test locked the six strips onto `nav_tabs`

**Where:** `test/phoenix_kit_crm/web/{contacts,companies,contact_show,company_show,lists,list_members}_live_test.exs`

The only existing tab assertion is contact-show's `a.tab-active` / `?tab=orders` clamp, written for the Orders soft-dep, not for this migration. A regression that swapped `:patch` for `:path` (double-prefix), dropped the Trashed tab's count condition, or left list-members' All tab unselected (`nil != "all"`) would not fail the suite.

**Fix applied:** added render assertions on all six pages for `role="tablist"` + `tabs-border`, the role-filter / show-tab patch hrefs, the Trashed tab appearing only once trash is non-empty, and list-members' All / Subscribed / Removed mapping.

### NITPICK — `filter_tabs/1` is duplicated between contacts and companies

Same five-role list, same Trashed condition, same `Kernel.++(if ...)`. Left as-is: the two path builders (`contacts_path/2` vs `companies_path/2`) are the only difference, and extracting a shared helper for two call sites is not worth a new module.
