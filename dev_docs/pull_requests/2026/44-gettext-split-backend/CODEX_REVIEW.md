# Codex review — PR #44 (2026-10-23)

PR: [Split the Gettext backend by locale and domain](https://github.com/BeamLabEU/phoenix_kit_crm/pull/44),
merged as `6926f73`. Rechecked the one-file diff, current backend, dependency
requirement, dynamic label callers, and locale tests.

No additional defect confirmed. The locale/domain split preserves the
backend API used by tabs, columns and runtime role labels. Existing tests
exercise English, Estonian and Russian labels, plural counts, locale
fallback, and renamed role labels against the compiled backend.

Also reviewed the subsequent party-role vocabulary and form changes in the
current tree: active/archived types, key immutability, built-in lifecycle
restrictions, validity windows, reconciliation of stale forms, translated
names, and V10 replay guards. No further confirmed defect in that scope.

Validation: [pre-live report](../../../reports/2026-10-23-prelive-review.md).
