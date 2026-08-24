# PR #27 — Codex review

**Reviewer**: Codex (gpt-5.6, `codex exec`, repo-anchored)
**Scope**: `upstream/main..main`, lib/ + tests
**Date**: 2026-08-24
**Method**: Read the diff and the surrounding code; concrete defects only

Verbatim output; every claim was re-verified against the code before acting — see `FOLLOW_UP.md` for the verdict on each.

---

- [company_show_live.ex:83](/Users/maxdon/Desktop/Elixir-servers/max-dev/phoenix_kit_crm/lib/phoenix_kit_crm/web/company_show_live.ex:83): Catalogue data and memberships are read before subscriptions are established at line 91. A concurrent committed broadcast in that gap is lost, leaving the initial page stale. Fix: subscribe first, then load catalogue/memberships and sync member topics.

- [company_show_live.ex:107](/Users/maxdon/Desktop/Elixir-servers/max-dev/phoenix_kit_crm/lib/phoenix_kit_crm/web/company_show_live.ex:107): Catalogue subscription reconciliation only runs when the company UUID changes. Enabling Catalogue while staying on the same company never subscribes; disabling it retains an unnecessary subscription. Fix: reconcile the catalogue topic independently on every `handle_params/3`.

- [contacts.ex:238](/Users/maxdon/Desktop/Elixir-servers/max-dev/phoenix_kit_crm/lib/phoenix_kit_crm/contacts.ex:238): `delete_contact/1` snapshots company UUIDs outside its transaction. A concurrent membership added after this query can be cascade-deleted without its company receiving `:member_left`, leaving that page stale. Fix: lock the contact and collect company UUIDs inside the delete transaction, returning them for post-commit broadcast.

- [contacts.ex:345](/Users/maxdon/Desktop/Elixir-servers/max-dev/phoenix_kit_crm/lib/phoenix_kit_crm/contacts.ex:345): `set_primary_company/4` also snapshots previous companies before its transaction. Concurrent setters can delete a newly committed membership while broadcasting `:member_left` only to an older snapshot. Fix: serialize on the contact and return the actual removed UUIDs from the transaction.

- [comparison_live.ex:41](/Users/maxdon/Desktop/Elixir-servers/max-dev/phoenix_kit_crm/lib/phoenix_kit_crm/web/comparison_live.ex:41): Reopening refreshes contact rows but never `duplicate_groups`; after an email changes, the obsolete group and count remain while its expanded rows show fewer contacts. Fix: re-query group summaries when reopening and discard groups no longer duplicated.

- [contacts_mirror_test.exs:152](/Users/maxdon/Desktop/Elixir-servers/max-dev/phoenix_kit_crm/test/phoenix_kit_crm/contacts_mirror_test.exs:152): The subscriber is the calling test process, so broadcasting inside the transaction would still pass—the message is inspected only after the function commits. Fix: use a separate subscriber that reads the contact immediately upon receipt and asserts the committed value.

- [settings_live_test.exs:27](/Users/maxdon/Desktop/Elixir-servers/max-dev/phoenix_kit_crm/test/phoenix_kit_crm/web/settings_live_test.exs:27): The test asserts only the redirect string; its destination is not mounted by [test_router.ex:59](/Users/maxdon/Desktop/Elixir-servers/max-dev/phoenix_kit_crm/test/support/test_router.ex:59), and sidebar contents are never checked. Fix: mount the production-shaped settings route, follow the redirect, and assert the role tab appears.
229 992
- [company_show_live.ex:83](/Users/maxdon/Desktop/Elixir-servers/max-dev/phoenix_kit_crm/lib/phoenix_kit_crm/web/company_show_live.ex:83): Catalogue data and memberships are read before subscriptions are established at line 91. A concurrent committed broadcast in that gap is lost, leaving the initial page stale. Fix: subscribe first, then load catalogue/memberships and sync member topics.

- [company_show_live.ex:107](/Users/maxdon/Desktop/Elixir-servers/max-dev/phoenix_kit_crm/lib/phoenix_kit_crm/web/company_show_live.ex:107): Catalogue subscription reconciliation only runs when the company UUID changes. Enabling Catalogue while staying on the same company never subscribes; disabling it retains an unnecessary subscription. Fix: reconcile the catalogue topic independently on every `handle_params/3`.

- [contacts.ex:238](/Users/maxdon/Desktop/Elixir-servers/max-dev/phoenix_kit_crm/lib/phoenix_kit_crm/contacts.ex:238): `delete_contact/1` snapshots company UUIDs outside its transaction. A concurrent membership added after this query can be cascade-deleted without its company receiving `:member_left`, leaving that page stale. Fix: lock the contact and collect company UUIDs inside the delete transaction, returning them for post-commit broadcast.

- [contacts.ex:345](/Users/maxdon/Desktop/Elixir-servers/max-dev/phoenix_kit_crm/lib/phoenix_kit_crm/contacts.ex:345): `set_primary_company/4` also snapshots previous companies before its transaction. Concurrent setters can delete a newly committed membership while broadcasting `:member_left` only to an older snapshot. Fix: serialize on the contact and return the actual removed UUIDs from the transaction.

- [comparison_live.ex:41](/Users/maxdon/Desktop/Elixir-servers/max-dev/phoenix_kit_crm/lib/phoenix_kit_crm/web/comparison_live.ex:41): Reopening refreshes contact rows but never `duplicate_groups`; after an email changes, the obsolete group and count remain while its expanded rows show fewer contacts. Fix: re-query group summaries when reopening and discard groups no longer duplicated.

- [contacts_mirror_test.exs:152](/Users/maxdon/Desktop/Elixir-servers/max-dev/phoenix_kit_crm/test/phoenix_kit_crm/contacts_mirror_test.exs:152): The subscriber is the calling test process, so broadcasting inside the transaction would still pass—the message is inspected only after the function commits. Fix: use a separate subscriber that reads the contact immediately upon receipt and asserts the committed value.

- [settings_live_test.exs:27](/Users/maxdon/Desktop/Elixir-servers/max-dev/phoenix_kit_crm/test/phoenix_kit_crm/web/settings_live_test.exs:27): The test asserts only the redirect string; its destination is not mounted by [test_router.ex:59](/Users/maxdon/Desktop/Elixir-servers/max-dev/phoenix_kit_crm/test/support/test_router.ex:59), and sidebar contents are never checked. Fix: mount the production-shaped settings route, follow the redirect, and assert the role tab appears.
