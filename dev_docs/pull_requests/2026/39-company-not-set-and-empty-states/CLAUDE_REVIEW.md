# Claude review — PR #39 "Say the company is not set, and what an empty company or project has" (2026-10-23)

Merged as `fd2de2c` (author mdon). Read: the four template/msgid edits
(`company_show_live`, `contact_form_live`, `project_client_live`), the new tests,
the et/ru catalogue entries. A Grok review already exists; this one is separate.

## Findings

None needing a change.

- **NITPICK: "Client not set." (project hub) and "— Company not set —" (contact form) are bare msgids with no context.** Gettext keys on the English string alone, so if a later screen wants a different meaning for the same words the catalogue cannot split them without `pgettext`. No clash today (each string is used once). Left.
- **NITPICK: the empty-state description on the company Members tab still says "linked"** ("…set the Company field on an existing contact's edit page") while the title was reworded away from it because "what does linked mean?". Wording call for the author; left.

## Checked, clean

- **No orphan msgids:** `— none —`, `No client linked to this project yet.` and `No contacts linked to this company yet.` are gone from `lib/` and from the catalogues; the three new msgids have et and ru translations (the `reworded empty labels are translated` test pins them via `Gettext.with_locale/3`).
- **The select's blank option still submits `""`**, so `company_uuid` semantics in the form are unchanged — only the visible prompt moved; the test addresses `#contact-company option[value='']`.
- **The project hub empty state** is still gated on "no client company in config" and the loading skeleton still refutes it.
