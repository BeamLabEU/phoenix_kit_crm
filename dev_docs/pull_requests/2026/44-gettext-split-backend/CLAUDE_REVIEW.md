# Claude review — PR #44 "Split the Gettext backend by locale and domain" (2026-10-23)

Merged as `6926f73` (author mdon). One file, `lib/phoenix_kit_crm/gettext.ex`:
`use Gettext.Backend, otp_app: :phoenix_kit_crm, split_module_by: [:locale, :domain]`.

## Findings

None that need a change.

- **NITPICK: the moduledoc says "Locale is set per-request by the parent application"** — still true, and the new comment explains the split. Nothing to add.

## Checked, clean

- **`split_module_by` is a Gettext 1.0 option**; the module requires `gettext ~> 1.0`, so no version gap. Lookups go through the same `Gettext.gettext/2,3` / `dgettext` / `ngettext` entry points, which dispatch to the per-locale/domain module — the dynamic lookups that CLAUDE.md calls out (`Gettext.gettext(backend, label)` for tab and column labels, `Gettext.with_locale/3` in the translation tests) are unaffected. The existing et/ru translation tests exercise exactly those paths and pass.
- **`.dialyzer_ignore.exs` still lists `gettext.ex :call_without_opaque`.** Left: the entry is for the macro-generated code, which the split changes in shape but not in kind; the gate is clean with it.
- **Extraction.** Splitting changes how the backend *compiles*, not what `mix gettext.extract` reads (the `.pot` is untouched).
