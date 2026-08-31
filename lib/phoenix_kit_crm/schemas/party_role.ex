defmodule PhoenixKitCRM.Schemas.PartyRole do
  @moduledoc """
  A commercial party role — marks an existing CRM company or contact as a
  `supplier`, `customer`, `partner`, or `manufacturer` (Odoo's
  `supplier_rank`/`customer_rank`, SAP's Business-Partner roles, expressed as
  rows). One party can hold several roles at once (a company that's both
  supplier and customer has two rows).

  `manufacturer` is the odd one out: in the catalogue a "manufacturer" is
  usually a *brand* — a product-master attribute — and the brand owner, the
  legal manufacturer and the supplier you actually buy from are frequently
  three different companies. The role is therefore granted on two paths only:
  the catalogue's link action (a human naming the real party) and the opt-in
  `mix phoenix_kit_crm.import_manufacturers_from_catalogue` backfill, which an
  operator runs deliberately and which is dry-run by default — never
  implicitly, and never from a form. Holding both `supplier` and
  `manufacturer` on one party is the case this shared table exists for.

  `roleable_type` + `roleable_uuid` point at `phoenix_kit_crm_companies` or
  `phoenix_kit_crm_contacts` — a **soft ref, no FK** (a single FK can't
  express the polymorphic target; integrity lives here in the changeset,
  mirroring the `staff_person_uuid` precedent on `InteractionParty`).

  `metadata` is never cast from raw UI params — the Roles checkboxes in the
  company/contact forms only ever toggle role membership via
  `PhoenixKitCRM.PartyRoles.grant_role/3` and `revoke_role/2`, which don't
  accept caller-supplied metadata either. Role-scoped commercial attributes
  land here only through a future dedicated context function.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @roleable_types ~w(company contact)
  @roles ~w(supplier customer partner manufacturer)

  @type t :: %__MODULE__{
          uuid: UUIDv7.t() | nil,
          roleable_type: String.t() | nil,
          roleable_uuid: UUIDv7.t() | nil,
          role: String.t() | nil,
          is_active: boolean(),
          valid_from: Date.t() | nil,
          valid_to: Date.t() | nil,
          metadata: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "phoenix_kit_crm_party_roles" do
    field(:roleable_type, :string)
    field(:roleable_uuid, UUIDv7)
    field(:role, :string)
    field(:is_active, :boolean, default: true)
    field(:valid_from, :date)
    field(:valid_to, :date)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime)
  end

  @castable ~w(roleable_type roleable_uuid role is_active valid_from valid_to)a

  @spec changeset(t() | Ecto.Changeset.t(t()), map()) :: Ecto.Changeset.t(t())
  def changeset(party_role, attrs) do
    party_role
    |> cast(attrs, @castable)
    |> validate_required([:roleable_type, :roleable_uuid, :role])
    |> validate_inclusion(:roleable_type, @roleable_types)
    |> validate_inclusion(:role, @roles, message: "must be one of: #{Enum.join(@roles, ", ")}")
    |> validate_date_range()
    |> unique_constraint([:roleable_type, :roleable_uuid, :role],
      name: :phoenix_kit_crm_party_roles_uniq,
      message: "already has this role"
    )
    # V04's partial index. Without naming it, a concurrent grant raises
    # Ecto.ConstraintError instead of returning a changeset, and which of the
    # two indexes fires is plan-dependent.
    |> unique_constraint([:roleable_uuid, :role],
      name: :phoenix_kit_crm_party_roles_active_uniq,
      message: "this party already holds that role"
    )
  end

  defp validate_date_range(changeset) do
    valid_from = get_field(changeset, :valid_from)
    valid_to = get_field(changeset, :valid_to)

    if valid_from && valid_to && Date.compare(valid_to, valid_from) == :lt do
      add_error(changeset, :valid_to, "can't be before valid_from")
    else
      changeset
    end
  end

  @doc """
  Changeset for controlled lifecycle transitions (revoke / reactivate) driven
  by the context, not user input. Deliberately skips `validate_date_range/1`:
  stamping `valid_to` = today when revoking a role whose `valid_from` is in the
  future would otherwise fail the ordering check and turn revoke into a silent
  no-op. Only `is_active` and `valid_to` are castable here.
  """
  @spec lifecycle_changeset(t() | Ecto.Changeset.t(t()), map()) :: Ecto.Changeset.t(t())
  def lifecycle_changeset(party_role, attrs) do
    cast(party_role, attrs, [:is_active, :valid_to])
  end

  @spec roleable_types() :: [String.t()]
  def roleable_types, do: @roleable_types

  @spec roles() :: [String.t()]
  def roles, do: @roles
end
