defmodule PhoenixKitCRM.PartyRolesManufacturerTest do
  @moduledoc """
  The `manufacturer` party role and the party-listing API.

  `get_manufacturer/1` is the contract
  `PhoenixKitCatalogue.Catalogue.Manufacturers.resolve/1` calls across the
  module boundary, so its return shape is pinned here the same way
  `get_supplier/1`'s is — the two now share one implementation, and these
  tests exist so a change to that shared code cannot silently reshape one
  of them.
  """
  use PhoenixKitCRM.DataCase, async: true

  alias PhoenixKitCRM.{Companies, Contacts, PartyRoles}
  alias PhoenixKitCRM.Schemas.PartyRole

  defp company_fixture(attrs \\ %{}) do
    {:ok, company} = Companies.create_company(Map.merge(%{"name" => "Bosch GmbH"}, attrs))
    company
  end

  defp contact_fixture(attrs) do
    {:ok, contact} = Contacts.create_contact(Map.merge(%{"name" => "Solo Maker"}, attrs))
    contact
  end

  describe "the manufacturer role" do
    test "is an accepted role value" do
      assert "manufacturer" in PartyRole.roles()
    end

    test "can be granted to a company" do
      company = company_fixture()

      assert {:ok, %PartyRole{} = role} = PartyRoles.grant_role(company, "manufacturer")
      assert role.role == "manufacturer"
      assert role.roleable_type == "company"
      assert PartyRoles.has_role?(company, "manufacturer")
    end

    test "coexists with the supplier role on one party — the case the shared table exists for" do
      company = company_fixture()

      assert {:ok, _} = PartyRoles.grant_role(company, "supplier")
      assert {:ok, _} = PartyRoles.grant_role(company, "manufacturer")

      assert PartyRoles.has_role?(company, "supplier")
      assert PartyRoles.has_role?(company, "manufacturer")
    end
  end

  describe "get_manufacturer/1" do
    test "returns the normalized party map for a company holding an active role" do
      company =
        company_fixture(%{
          "name" => "Bosch GmbH",
          "email" => "sales@bosch.example",
          "phone" => "+49 1234",
          "website" => "https://bosch.example"
        })

      {:ok, _} = PartyRoles.grant_role(company, "manufacturer")

      assert %{
               uuid: uuid,
               name: "Bosch GmbH",
               email: "sales@bosch.example",
               phone: "+49 1234",
               website: "https://bosch.example",
               source: :crm
             } = PartyRoles.get_manufacturer(company.uuid)

      assert uuid == company.uuid
    end

    test "resolves a contact too — a sole trader can be a manufacturer" do
      contact = contact_fixture(%{"name" => "Solo Maker", "email" => "solo@maker.example"})
      {:ok, _} = PartyRoles.grant_role(contact, "manufacturer")

      party = PartyRoles.get_manufacturer(contact.uuid)

      assert party.name == "Solo Maker"
      assert party.source == :crm
      # Contacts carry no website column; the shape still declares the key.
      assert party.website == nil
    end

    test "returns nil when the party holds a DIFFERENT role" do
      company = company_fixture()
      {:ok, _} = PartyRoles.grant_role(company, "supplier")

      assert PartyRoles.get_manufacturer(company.uuid) == nil
    end

    test "returns nil once the role is revoked" do
      company = company_fixture()
      {:ok, _} = PartyRoles.grant_role(company, "manufacturer")
      {:ok, _} = PartyRoles.revoke_role(company, "manufacturer")

      assert PartyRoles.get_manufacturer(company.uuid) == nil
    end

    test "returns nil for an unknown or malformed uuid rather than raising" do
      assert PartyRoles.get_manufacturer(Ecto.UUID.generate()) == nil
      assert PartyRoles.get_manufacturer("not-a-uuid") == nil
      assert PartyRoles.get_manufacturer(nil) == nil
    end

    test "get_supplier/1 keeps its own shape — the shared implementation did not blur the roles" do
      company = company_fixture(%{"name" => "Dual Role Ltd"})
      {:ok, _} = PartyRoles.grant_role(company, "supplier")

      assert %{name: "Dual Role Ltd", source: :crm} = PartyRoles.get_supplier(company.uuid)
      assert PartyRoles.get_manufacturer(company.uuid) == nil
    end
  end

  describe "list_parties_with_role/2 and its role-specific wrappers" do
    test "returns companies then contacts, each tagged with its specific source" do
      company = company_fixture(%{"name" => "Aaa Manufacturing"})
      contact = contact_fixture(%{"name" => "Zzz Sole Trader"})

      {:ok, _} = PartyRoles.grant_role(company, "manufacturer")
      {:ok, _} = PartyRoles.grant_role(contact, "manufacturer")

      assert [first, second] = PartyRoles.list_manufacturers()

      assert first.uuid == company.uuid
      assert first.source == :crm_company
      assert second.uuid == contact.uuid
      assert second.source == :crm_contact
    end

    test "the specific source tag is what a caller persists, so it must not be the generic :crm" do
      company = company_fixture()
      {:ok, _} = PartyRoles.grant_role(company, "supplier")

      assert [%{source: :crm_company}] = PartyRoles.list_suppliers()
    end

    test "each wrapper returns only its own role" do
      supplier = company_fixture(%{"name" => "Supplier Co"})
      maker = company_fixture(%{"name" => "Maker Co"})
      customer = company_fixture(%{"name" => "Customer Co"})

      {:ok, _} = PartyRoles.grant_role(supplier, "supplier")
      {:ok, _} = PartyRoles.grant_role(maker, "manufacturer")
      {:ok, _} = PartyRoles.grant_role(customer, "customer")

      assert [%{uuid: s}] = PartyRoles.list_suppliers()
      assert [%{uuid: m}] = PartyRoles.list_manufacturers()
      assert [%{uuid: c}] = PartyRoles.list_customers()

      assert s == supplier.uuid
      assert m == maker.uuid
      assert c == customer.uuid
    end

    test "excludes revoked roles" do
      company = company_fixture()
      {:ok, _} = PartyRoles.grant_role(company, "manufacturer")
      {:ok, _} = PartyRoles.revoke_role(company, "manufacturer")

      assert PartyRoles.list_manufacturers() == []
    end

    test "passes options through to the underlying role listings" do
      for n <- 1..3 do
        company = company_fixture(%{"name" => "Maker #{n}"})
        {:ok, _} = PartyRoles.grant_role(company, "manufacturer")
      end

      assert length(PartyRoles.list_manufacturers(limit: 2)) == 2
    end
  end
end
