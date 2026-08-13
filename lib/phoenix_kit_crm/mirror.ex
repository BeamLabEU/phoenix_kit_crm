defmodule PhoenixKitCRM.Mirror do
  @moduledoc """
  Field maps and the per-field divergence-diff engine shared by both mirror
  sides — `Company` ↔ an `account_type: "organization"` `User`, `Contact` ↔
  an `account_type: "person"` `User` (owner decisions Q1-Q6, `L006`).

  Pure functions over structs: no DB access, no context calls. Every
  writing decision ("actually link/create/copy") lives in the `Companies`
  / `Contacts` contexts (Tasks D/E); this module only computes what would
  change and whether that change is safe to make silently.

  ## The rule this module exists to enforce

  "Master = the side the form you're on transfers FROM." When both sides
  already carry a NON-BLANK value and those values genuinely differ, that
  is a **conflict** — `diff/2` surfaces it and the caller must ask (the
  conflict modal, Task F), never silently overwrite. When one side is
  blank, the copy just fills it — not a conflict.

  ## Field maps

  `field_map/1` returns one entry per mirrored field:

    * `%{crm: atom(), user: atom(), label: String.t()}` — a direct 1:1
      copy (`:email`, and `:name` ↔ `:organization_name` for `:company`).
    * `%{crm: :name, user: {:split, :first_name, :last_name}, label: ...}`
      — `:contact` only. `User` has no single "name" column; `Contact.name`
      is the JOIN of `first_name` + `last_name` (see below), so there is
      no single user-side atom this field's value lives in.

  Only fields that exist on BOTH `Contact`/`Company` and `User` participate
  — `Company.website`/`.phone`/`.address`/`.industry` and `Contact.phone`/
  `.locale` have no `User` counterpart (User has no `phone`, no `locale`)
  and are deliberately absent from both maps (Q4).

  ## `diff/2`'s `:field` key

  For a direct mapping, `:field` is the **user-side** atom (`:email`,
  `:organization_name`) — the column a resolver would `put_change/3` when
  the CRM side wins. For the contact name mapping there is no single
  user-side atom (it is two columns), so `:field` is the **symbolic**
  `:name` instead; a resolver must special-case `:name` (same as it
  special-cases nothing for the direct fields — those genuinely are a raw
  copy) and go through `attrs_from/2` / `attrs_to_crm/2` rather than a bare
  `put_change/3`, exactly like it already has to for the direct fields'
  values (a blank company `website` isn't part of this diff at all, but a
  resolver writing `:organization_name` still calls into the `Companies`
  context, never touches `Ecto.Changeset` directly).

  ## Name join / split

  `User` has no combined name field; `Contact`/`Company` conflate the
  mirror's "name" concept differently:

    * **join** (`User` → CRM, `attrs_to_crm/2`, contact only):
      `String.trim("\#{first_name} \#{last_name}")`, collapsing to `nil`
      when both sides are blank.
    * **split** (CRM → `User`, `attrs_from/2`, contact only): split on the
      LAST run of whitespace — everything before it becomes `first_name`,
      the trailing token becomes `last_name`. A single token sets
      `first_name` and leaves `last_name` `nil`. A blank name yields `nil`
      for both.
  """

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitCRM.Schemas.{Company, Contact}

  @type kind :: :company | :contact
  @type user_field :: atom() | {:split, atom(), atom()}
  @type field_map_entry :: %{crm: atom(), user: user_field(), label: String.t()}

  @company_field_map [
    %{crm: :name, user: :organization_name, label: "Name"},
    %{crm: :email, user: :email, label: "Email"}
  ]

  @contact_field_map [
    %{crm: :name, user: {:split, :first_name, :last_name}, label: "Name"},
    %{crm: :email, user: :email, label: "Email"}
  ]

  @doc "The mapped fields for `kind` — only fields present on both sides."
  @spec field_map(kind()) :: [field_map_entry()]
  def field_map(:company), do: @company_field_map
  def field_map(:contact), do: @contact_field_map

  @doc """
  The per-field divergences between a CRM record and a `User` — only
  fields present (non-blank) on BOTH sides AND unequal. See the moduledoc
  for what `:field` holds for the contact name mapping.
  """
  @spec diff(Company.t() | Contact.t(), User.t()) :: [
          %{field: atom(), label: String.t(), crm: term(), user: term()}
        ]
  def diff(%Company{} = company, %User{} = user), do: diff(:company, company, user)
  def diff(%Contact{} = contact, %User{} = user), do: diff(:contact, contact, user)

  defp diff(kind, crm_struct, user) do
    kind
    |> field_map()
    |> Enum.flat_map(fn %{crm: crm_field, user: user_field, label: label} ->
      crm_value = blank_to_nil(Map.fetch!(crm_struct, crm_field))
      user_value = blank_to_nil(user_value(user_field, user))

      if crm_value != nil and user_value != nil and crm_value != user_value do
        [%{field: diff_field(user_field), label: label, crm: crm_value, user: user_value}]
      else
        []
      end
    end)
  end

  defp diff_field({:split, _first, _last}), do: :name
  defp diff_field(user_field) when is_atom(user_field), do: user_field

  defp user_value({:split, first_field, last_field}, user) do
    join_name(Map.fetch!(user, first_field), Map.fetch!(user, last_field))
  end

  defp user_value(user_field, user) when is_atom(user_field), do: Map.fetch!(user, user_field)

  @doc """
  The `User` attrs to write when the CRM record is master (a "create
  mirror user" or "CRM wins this conflict" write).
  """
  @spec attrs_from(kind(), Company.t() | Contact.t()) :: map()
  def attrs_from(:company, %Company{} = company) do
    %{
      account_type: "organization",
      organization_name: blank_to_nil(company.name),
      email: blank_to_nil(company.email)
    }
  end

  def attrs_from(:contact, %Contact{} = contact) do
    {first_name, last_name} = split_name(contact.name)

    %{
      account_type: "person",
      first_name: first_name,
      last_name: last_name,
      email: blank_to_nil(contact.email)
    }
  end

  @doc """
  The CRM attrs to write when the `User` is master (a "create CRM card
  from user" or "User wins this conflict" write).
  """
  @spec attrs_to_crm(kind(), User.t()) :: map()
  def attrs_to_crm(:company, %User{} = user) do
    %{name: blank_to_nil(user.organization_name), email: blank_to_nil(user.email)}
  end

  def attrs_to_crm(:contact, %User{} = user) do
    %{name: join_name(user.first_name, user.last_name), email: blank_to_nil(user.email)}
  end

  # ── name join / split ────────────────────────────────────────────────

  defp join_name(first_name, last_name) do
    [first_name, last_name]
    |> Enum.map(&(&1 || ""))
    |> Enum.join(" ")
    |> String.trim()
    |> blank_to_nil()
  end

  defp split_name(nil), do: {nil, nil}

  defp split_name(name) when is_binary(name) do
    case name |> String.trim() |> blank_to_nil() do
      nil ->
        {nil, nil}

      trimmed ->
        case String.split(trimmed, ~r/\s+/, trim: true) do
          [single] -> {single, nil}
          tokens -> {tokens |> Enum.drop(-1) |> Enum.join(" "), List.last(tokens)}
        end
    end
  end

  # ── shared ────────────────────────────────────────────────────────────

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
