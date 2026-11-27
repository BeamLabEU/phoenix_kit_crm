defmodule PhoenixKitCRM.CatalogueImportContactsTest do
  @moduledoc """
  The supplier backfill carrying catalogue V7's primary contacts, with the
  catalogue's tables present and without its contacts table (an older
  catalogue). The tables are created inside the sandbox transaction, so
  the test needs no catalogue install and leaves nothing behind.
  """
  use PhoenixKitCRM.DataCase, async: false

  alias PhoenixKitCRM.{CatalogueImport, Companies}

  @moduletag :integration

  @prefix "public"

  setup do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.phoenix_kit_cat_suppliers (
      uuid uuid PRIMARY KEY, name varchar(255), status varchar(20),
      contact_info varchar(500), website varchar(500), notes text,
      description text, crm_company_uuid uuid
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS public.phoenix_kit_cat_supplier_contacts (
      uuid uuid DEFAULT gen_random_uuid() PRIMARY KEY, supplier_uuid uuid NOT NULL,
      kind varchar(20) NOT NULL, value varchar(500) NOT NULL, label varchar(255),
      is_primary boolean DEFAULT false NOT NULL, position integer DEFAULT 0 NOT NULL,
      inserted_at timestamptz DEFAULT now() NOT NULL, updated_at timestamptz DEFAULT now() NOT NULL
    )
    """)

    :ok
  end

  defp supplier!(attrs) do
    uuid = Ecto.UUID.generate()

    row =
      Map.merge(
        %{
          uuid: uuid,
          name: "Kraana #{System.unique_integer([:positive])}",
          status: "active",
          contact_info: nil,
          website: nil,
          notes: nil,
          description: nil,
          crm_company_uuid: nil
        },
        attrs
      )

    Repo.query!(
      "INSERT INTO public.phoenix_kit_cat_suppliers (uuid, name, status, contact_info, website) " <>
        "VALUES ($1, $2, $3, $4, $5)",
      [Ecto.UUID.dump!(uuid), row.name, row.status, row.contact_info, row.website]
    )

    row
  end

  defp contact!(supplier, kind, value, primary? \\ true) do
    Repo.query!(
      "INSERT INTO public.phoenix_kit_cat_supplier_contacts (supplier_uuid, kind, value, is_primary) " <>
        "VALUES ($1, $2, $3, $4)",
      [Ecto.UUID.dump!(supplier.uuid), kind, value, primary?]
    )
  end

  defp import!(row),
    do: CatalogueImport.process_row(row, Repo, @prefix, true, CatalogueImport.config(:suppliers))

  defp members(company_uuid),
    do: company_uuid |> Companies.list_memberships() |> Enum.map(& &1.contact.name)

  test "a new company gets the primaries: email, phone, web address, and the person" do
    s = supplier!(%{contact_info: "Mari Maasikas, +372 5555 1234, sales@kraana.ee"})
    contact!(s, "email", "Sales@Kraana.ee")
    contact!(s, "phone", "+372 5555 1234")
    contact!(s, "url", "https://kraana.ee")
    contact!(s, "person", "Mari Maasikas")
    contact!(s, "email", "old@kraana.ee", false)

    assert %{action: :created, company_uuid: uuid} = import!(s)
    company = Companies.get_company(uuid)

    assert {company.email, company.phone, company.website} ==
             {"sales@kraana.ee", "+372 5555 1234", "https://kraana.ee"}

    assert members(uuid) == ["Mari Maasikas"]
  end

  test "a matched company keeps what it has and gets only its blanks" do
    {:ok, existing} =
      Companies.create_company(%{
        "name" => "Kraana OÜ",
        "email" => "sales@kraana.ee",
        "phone" => "+372 1111 1111"
      })

    s = supplier!(%{})
    contact!(s, "email", "sales@kraana.ee")
    contact!(s, "phone", "+372 5555 1234")
    contact!(s, "url", "https://kraana.ee")
    contact!(s, "person", "Mari Maasikas")

    assert %{action: :matched_by_email, company_uuid: uuid} = import!(s)
    assert uuid == existing.uuid
    company = Companies.get_company(uuid)
    assert {company.phone, company.website} == {"+372 1111 1111", "https://kraana.ee"}
    assert members(uuid) == ["Mari Maasikas"]

    # A second supplier on the same company with the same person adds no one.
    s2 = supplier!(%{})
    contact!(s2, "email", "sales@kraana.ee")
    contact!(s2, "person", "mari maasikas")
    assert %{action: :already_claimed} = import!(s2)
    assert members(uuid) == ["Mari Maasikas"]
  end

  test "without the contacts table the free text is used, as before" do
    Repo.query!("DROP TABLE public.phoenix_kit_cat_supplier_contacts")
    config = CatalogueImport.config(:suppliers)
    assert CatalogueImport.primary_contacts(Repo, @prefix, Ecto.UUID.generate(), config) == %{}

    s = supplier!(%{contact_info: "call Mari: sales@kraana.ee"})
    assert %{action: :created, company_uuid: uuid} = import!(s)
    company = Companies.get_company(uuid)
    assert company.email == "sales@kraana.ee"
    assert company.phone == nil
    assert members(uuid) == []
  end

  test "manufacturers carry no contacts" do
    assert CatalogueImport.primary_contacts(
             Repo,
             @prefix,
             Ecto.UUID.generate(),
             CatalogueImport.config(:manufacturers)
           ) == %{}
  end
end
