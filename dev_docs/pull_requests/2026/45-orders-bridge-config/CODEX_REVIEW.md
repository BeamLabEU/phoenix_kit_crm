# Codex review — PR #45 (2026-10-23)

PR: [Configure the Orders tab bridge](https://github.com/BeamLabEU/phoenix_kit_crm/pull/45),
merged as `9dc000e`. Rechecked the complete production diff and the follow-up
malformed-row filtering in `4f1db32`, including runtime bridge selection,
tab availability, loading, rendering, and failure isolation.

## Finding fixed

**BUG - MEDIUM: a timed-out bridge call still crashed the contact LiveView.**
`rescue` handles raised exceptions but not exits such as a failed
`GenServer.call`. A host bridge calling an unavailable orders service could
therefore take down the contact profile. `load_contact_orders/3` now catches
exits and throws, logs the failure, and returns the existing empty state.

A bridge collaborator exits with a GenServer timeout. Its LiveView test
failed before the fix and now verifies that the Orders tab and contact page
continue rendering. Existing tests cover a raised exception, malformed rows,
a non-list answer, an unavailable module, and a valid runtime-configured
bridge.

The host must still configure `:orders_bridge` to expose the tab; this is
the intended migration from the former host-specific module name.

Validation: [pre-live report](../../../reports/2026-10-23-prelive-review.md).
