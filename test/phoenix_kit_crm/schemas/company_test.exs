defmodule PhoenixKitCRM.Schemas.CompanyTest do
  @moduledoc """
  Pins the `Company.user_uuid` mirror link (the organization-user
  counterpart to `Contact.user_uuid`): settable/clearable only through
  `link_user_changeset/2`, never through the public `changeset/2` — a
  crafted form payload must not be able to link an arbitrary user. Mirrors
  `Contact.link_user_changeset/2`'s contract exactly.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitCRM.Schemas.Company

  describe "user_uuid is not castable from form params" do
    test "changeset/2 never casts user_uuid, even when present in attrs" do
      uuid = UUIDv7.generate()

      cs = Company.changeset(%Company{name: "Acme"}, %{"user_uuid" => uuid})

      refute Map.has_key?(cs.changes, :user_uuid)
    end
  end

  describe "link_user_changeset/2" do
    test "sets user_uuid on an unlinked company" do
      uuid = UUIDv7.generate()

      changeset = Company.link_user_changeset(%Company{name: "Acme"}, uuid)

      assert Ecto.Changeset.get_change(changeset, :user_uuid) == uuid
    end

    test "clears user_uuid when given nil" do
      uuid = UUIDv7.generate()

      changeset =
        Company.link_user_changeset(%Company{name: "Acme", user_uuid: uuid}, nil)

      assert Ecto.Changeset.get_change(changeset, :user_uuid) == nil
    end

    test "carries the idx_crm_companies_user_uuid unique constraint (one company per user)" do
      uuid = UUIDv7.generate()

      changeset = Company.link_user_changeset(%Company{name: "Acme"}, uuid)

      assert [%{field: :user_uuid, constraint: "idx_crm_companies_user_uuid", type: :unique}] =
               changeset.constraints
    end
  end
end
