# Dialyzer warnings to ignore (matched by dialyxir).
#
# Gettext 1.0 + Expo 1.1 generate a `Gettext.Plural.plural/2` call against Expo's
# *opaque* `PluralForms` struct inside the generated backend (`use Gettext.Backend`),
# which Dialyzer reports as `call_without_opaque` at `gettext.ex:1`. It's a known
# upstream false positive in code we don't author — scoped narrowly to the backend
# module and that one warning type so real issues elsewhere still surface.
#
# `Lists.Import.new_accumulator/0` returns `{%ImportReport{}, MapSet.new()}` with
# `@spec ... :: {ImportReport.t(), MapSet.t()}` — a completely ordinary use of
# `MapSet.t()`. Dialyzer flags it `contract_with_opaque` because the function body
# constructs the `MapSet.t()` value directly in the same module whose spec exposes
# it, and its success-typing analysis then "sees" MapSet's internal (opaque)
# `:map` field structurally. This is the same class of stdlib opaque-type false
# positive as the Gettext entry above, not a real type error.
[
  {"lib/phoenix_kit_crm/gettext.ex", :call_without_opaque},
  {"lib/phoenix_kit_crm/lists/import.ex", :contract_with_opaque}
]
