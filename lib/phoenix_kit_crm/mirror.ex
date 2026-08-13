defmodule PhoenixKitCRM.Mirror do
  @moduledoc """
  Field maps, the per-field divergence-diff engine, and the resolver they
  feed — shared by both mirror sides: `Company` ↔ an
  `account_type: "organization"` `User`, `Contact` ↔ an
  `account_type: "person"` `User` (owner decisions Q1-Q6, `L006`).

  Pure functions over structs: no DB access, no context calls. Every
  writing decision ("actually link/create/copy") lives in the `Companies`
  / `Contacts` contexts (Tasks D/E); this module only computes what would
  change, whether that change is safe to make silently, and — once a
  human has picked a side per field — exactly what to write.

  ## The rule this module exists to enforce

  "Master = the side the form you're on transfers FROM." When both sides
  already carry a NON-BLANK value and those values genuinely differ, that
  is a **conflict** — `diff/2` surfaces it and the caller must ask (the
  conflict modal, Task F), never silently overwrite. When one side is
  blank, the copy just fills it — not a conflict. Values are compared
  trimmed (`" Anna Kask "` and `"Anna Kask"` are the same value, on
  either side), so incidental whitespace never manufactures a false
  conflict.

  ## Field maps

  `field_map/1` returns one entry per mirrored field:

    * `%{crm: atom(), user: atom(), label: String.t()}` — a direct 1:1
      copy (`:email` for both kinds; `:name` ↔ `:organization_name` for
      `:company`).
    * `%{crm: :name, user: {:split, :first_name, :last_name}, label: ...}`
      — `:contact` only. `User` has no single "name" column; `Contact.name`
      is the JOIN of `first_name` + `last_name` (see below), so there is
      no single user-side atom this field's value lives in.

  Only fields that exist on BOTH `Contact`/`Company` and `User` participate
  — `Company.website`/`.phone`/`.address`/`.industry` and `Contact.phone`/
  `.locale` have no `User` counterpart (User has no `phone`, no `locale`)
  and are deliberately absent from both maps (Q4).

  ## The `:field` key is symbolic, not a raw column

  `diff/2` and `resolve/4` both key on the **CRM-side atom** (`:name`,
  `:email`) for BOTH kinds, uniformly — never a raw `User` column like
  `:organization_name` or `:first_name`, even for the direct mappings
  where `crm` and `user` atoms happen to share a name (`:email`). This is
  deliberate: a caller must never `Ecto.Changeset.put_change(cs, field,
  value)` a `diff/2` entry directly (that would silently break the
  contact name mapping, which needs two columns written from one value).
  Callers pick a side per symbolic field and hand the choices to
  `resolve/4`, which owns all split/join + direction logic centrally —
  LiveViews (Tasks F/G/H) never see `first_name`/`last_name`/
  `organization_name` at all.

  ## Name join / split

  `User` has no combined name field; `Contact` conflates the mirror's
  "name" concept differently (`:company`'s `name` maps straight to
  `organization_name`, no join/split involved):

    * **join** (`User` → CRM, `attrs_to_crm/2` and `resolve/4`, contact
      only): `String.trim("\#{first_name} \#{last_name}")`, collapsing to
      `nil` when both sides are blank.
    * **split** (CRM → `User`, `attrs_from/2` and `resolve/4`, contact
      only): tokenize on whitespace (any run) — the LAST token becomes
      `last_name`, every token before it rejoins with a single space to
      become `first_name`. This collapses internal multi-space/tab runs
      to a single space; it does not preserve original in-between
      spacing. A single token sets `first_name` and leaves `last_name`
      `nil`. A blank name yields `nil` for both.
  """

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitCRM.Schemas.{Company, Contact}

  @type kind :: :company | :contact
  @type user_field :: atom() | {:split, atom(), atom()}
  @type field_map_entry :: %{crm: atom(), user: user_field(), label: String.t()}
  @type side :: :crm | :user

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
  fields present (non-blank, trimmed) on BOTH sides AND unequal. `:field`
  is the symbolic key described in the moduledoc (`:name` / `:email` for
  both kinds) — feed it straight to `resolve/4`, never to `put_change/3`.
  """
  @spec diff(Company.t() | Contact.t(), User.t()) :: [
          %{field: atom(), label: String.t(), crm: term(), user: term()}
        ]
  def diff(%Company{} = company, %User{} = user), do: diff(:company, company, user)
  def diff(%Contact{} = contact, %User{} = user), do: diff(:contact, contact, user)

  defp diff(kind, crm_struct, user) do
    kind
    |> field_map()
    |> Enum.flat_map(fn %{crm: crm_field, user: user_field, label: label} = entry ->
      if diverges?(entry, crm_struct, user) do
        crm_val = normalize(Map.fetch!(crm_struct, crm_field))
        user_val = normalize(user_value(user_field, user))
        [%{field: crm_field, label: label, crm: crm_val, user: user_val}]
      else
        []
      end
    end)
  end

  @doc """
  Turns a human's per-field side choice into the attr deltas each side
  needs written — the single place split/join + direction logic lives.

  `choices` is `%{symbolic_field => :crm | :user}` (the same `:field` keys
  `diff/2` emits, e.g. `%{name: :crm, email: :user}`). A field is a no-op
  — contributes nothing to either delta — when it's absent from `choices`
  (no conflict on it, or the caller chose not to touch it) OR when it's
  present but the two sides don't actually diverge (the same non-blank
  fields — a defensive guard, not just a caller contract, since blindly
  honoring a stray choice on a non-diverging field can WIPE a populated
  side: e.g. `%Contact{name: nil}` + `%{name: :crm}` would otherwise null
  out an already-set `first_name`/`last_name`).

    * choice `:crm` on a genuinely diverging field → that field's CRM
      value wins; the delta needed to bring `User` in line goes into
      `:user` (split into `first_name`/`last_name` for the contact name
      mapping, a plain `%{field => value}` otherwise). The `:crm` side of
      the result is untouched for that field — it already holds the
      winning value.
    * choice `:user` on a genuinely diverging field → the reverse: the
      delta needed to bring the CRM record in line goes into `:crm`
      (joined for the contact name mapping), `:user` untouched for that
      field.

  Returns `%{crm: map(), user: map()}` — attrs to pass into the
  `Companies`/`Contacts` and `Auth` update calls respectively.
  """
  @spec resolve(kind(), Company.t() | Contact.t(), User.t(), %{atom() => side()}) :: %{
          crm: map(),
          user: map()
        }
  def resolve(kind, crm_struct, %User{} = user, choices) when is_map(choices) do
    kind
    |> field_map()
    |> Enum.reduce(%{crm: %{}, user: %{}}, fn %{crm: crm_field, user: user_field} = entry, acc ->
      choice = Map.get(choices, crm_field)

      if choice in [:crm, :user] and diverges?(entry, crm_struct, user) do
        apply_choice(acc, choice, crm_field, user_field, crm_struct, user)
      else
        acc
      end
    end)
  end

  defp apply_choice(acc, :crm, crm_field, user_field, crm_struct, _user) do
    crm_val = normalize(Map.fetch!(crm_struct, crm_field))
    %{acc | user: Map.merge(acc.user, user_attrs_for(user_field, crm_val))}
  end

  defp apply_choice(acc, :user, crm_field, user_field, _crm_struct, user) do
    user_val = normalize(user_value(user_field, user))
    %{acc | crm: Map.merge(acc.crm, %{crm_field => user_val})}
  end

  # Same non-blank-and-unequal predicate `diff/2` surfaces a conflict
  # with — `resolve/4` reuses it so a choice can never act on a field
  # that isn't genuinely diverging.
  defp diverges?(%{crm: crm_field, user: user_field}, crm_struct, user) do
    crm_val = normalize(Map.fetch!(crm_struct, crm_field))
    user_val = normalize(user_value(user_field, user))
    crm_val != nil and user_val != nil and crm_val != user_val
  end

  defp user_value({:split, first_field, last_field}, user) do
    join_name(Map.fetch!(user, first_field), Map.fetch!(user, last_field))
  end

  defp user_value(user_field, user) when is_atom(user_field), do: Map.fetch!(user, user_field)

  defp user_attrs_for({:split, first_field, last_field}, crm_value) do
    {first_name, last_name} = split_name(crm_value)
    %{first_field => first_name, last_field => last_name}
  end

  defp user_attrs_for(user_field, value) when is_atom(user_field) do
    %{user_field => value}
  end

  @doc """
  The `User` attrs to write when the CRM record is master (a "create
  mirror user" or "CRM wins this conflict" write). Values are normalized
  (trimmed + blanked-to-nil) the same way `diff/2`/`resolve/4` normalize
  them, so a padded form value never persists untrimmed via this path
  while `resolve/4` would have trimmed it.
  """
  @spec attrs_from(kind(), Company.t() | Contact.t()) :: map()
  def attrs_from(:company, %Company{} = company) do
    %{
      account_type: "organization",
      organization_name: normalize(company.name),
      email: normalize(company.email)
    }
  end

  def attrs_from(:contact, %Contact{} = contact) do
    {first_name, last_name} = split_name(contact.name)

    %{
      account_type: "person",
      first_name: first_name,
      last_name: last_name,
      email: normalize(contact.email)
    }
  end

  @doc """
  The CRM attrs to write when the `User` is master (a "create CRM card
  from user" or "User wins this conflict" write). Same normalization
  guarantee as `attrs_from/2` — see its `@doc`.
  """
  @spec attrs_to_crm(kind(), User.t()) :: map()
  def attrs_to_crm(:company, %User{} = user) do
    %{name: normalize(user.organization_name), email: normalize(user.email)}
  end

  def attrs_to_crm(:contact, %User{} = user) do
    %{name: join_name(user.first_name, user.last_name), email: normalize(user.email)}
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

  # Trims a string (so incidental whitespace never manufactures a false
  # conflict or writes a stray "" instead of nil), then blank_to_nil.
  # Applied symmetrically to both sides of every comparison and every
  # value resolve/4 writes.
  defp normalize(value) when is_binary(value), do: value |> String.trim() |> blank_to_nil()
  defp normalize(value), do: blank_to_nil(value)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
