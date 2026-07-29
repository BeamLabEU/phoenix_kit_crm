defmodule PhoenixKitCRM.PartyRolesTest do
  use PhoenixKitCRM.DataCase, async: true

  import PhoenixKitCRM.ActivityLogAssertions

  alias PhoenixKitCRM.{Companies, Contacts, PartyRoles}
  alias PhoenixKitCRM.Schemas.PartyRole

  defp company_fixture(attrs \\ %{}) do
    {:ok, company} =
      Companies.create_company(Map.merge(%{"name" => "Acme Supplies"}, attrs))

    company
  end

  defp contact_fixture(attrs \\ %{}) do
    {:ok, contact} =
      Contacts.create_contact(Map.merge(%{"name" => "Jane Trader"}, attrs))

    contact
  end

  describe "grant_role/3" do
    test "grants a role to a company" do
      company = company_fixture()

      assert {:ok, %PartyRole{} = role} = PartyRoles.grant_role(company, "supplier")
      assert role.roleable_type == "company"
      assert role.roleable_uuid == company.uuid
      assert role.role == "supplier"
      assert role.is_active
    end

    test "grants a role to a contact" do
      contact = contact_fixture()

      assert {:ok, %PartyRole{roleable_type: "contact"}} =
               PartyRoles.grant_role(contact, "supplier")

      assert PartyRoles.has_role?(contact, "supplier")
    end

    test "is idempotent for an already-active role" do
      company = company_fixture()
      {:ok, first} = PartyRoles.grant_role(company, "customer")

      assert {:ok, second} = PartyRoles.grant_role(company, "customer")
      assert second.uuid == first.uuid
      assert [_only_one] = PartyRoles.list_roles(company)
    end

    test "reactivates a revoked role and clears valid_to" do
      company = company_fixture()
      {:ok, granted} = PartyRoles.grant_role(company, "supplier")
      {:ok, revoked} = PartyRoles.revoke_role(company, "supplier")
      refute revoked.is_active
      assert revoked.valid_to

      assert {:ok, regranted} = PartyRoles.grant_role(company, "supplier")
      assert regranted.uuid == granted.uuid
      assert regranted.is_active
      assert regranted.valid_to == nil
    end

    test "one party can hold supplier and customer simultaneously" do
      company = company_fixture()
      assert {:ok, _} = PartyRoles.grant_role(company, "supplier")
      assert {:ok, _} = PartyRoles.grant_role(company, "customer")

      assert PartyRoles.has_role?(company, "supplier")
      assert PartyRoles.has_role?(company, "customer")
      assert length(PartyRoles.list_roles(company)) == 2
    end

    test "rejects an unknown role" do
      company = company_fixture()
      assert {:error, cs} = PartyRoles.grant_role(company, "vendor")
      assert cs.errors[:role]
    end

    test "rejects valid_to before valid_from" do
      company = company_fixture()

      assert {:error, cs} =
               PartyRoles.grant_role(company, "supplier", %{
                 valid_from: ~D[2026-07-01],
                 valid_to: ~D[2026-06-01]
               })

      assert cs.errors[:valid_to]
    end

    test "logs the granting activity with the given actor_uuid" do
      company = company_fixture()
      actor_uuid = Ecto.UUID.generate()

      assert {:ok, _} = PartyRoles.grant_role(company, "supplier", %{}, actor_uuid: actor_uuid)

      assert_activity_logged("crm.party_role_granted",
        resource_uuid: company.uuid,
        actor_uuid: actor_uuid
      )
    end

    test "an idempotent re-grant of an already-active role does not log again" do
      company = company_fixture()
      actor_uuid = Ecto.UUID.generate()
      {:ok, _} = PartyRoles.grant_role(company, "supplier", %{}, actor_uuid: actor_uuid)

      assert {:ok, _} = PartyRoles.grant_role(company, "supplier")

      assert_activity_logged("crm.party_role_granted",
        resource_uuid: company.uuid,
        actor_uuid: actor_uuid
      )
    end
  end

  describe "revoke_role/2" do
    test "deactivates and stamps valid_to, keeping the row" do
      company = company_fixture()
      {:ok, _} = PartyRoles.grant_role(company, "supplier")

      assert {:ok, %PartyRole{} = revoked} = PartyRoles.revoke_role(company, "supplier")
      refute revoked.is_active
      assert revoked.valid_to == Date.utc_today()
      refute PartyRoles.has_role?(company, "supplier")
      assert [_kept_row] = PartyRoles.list_roles(company)
    end

    test "returns not_found for a never-granted role" do
      assert {:error, :not_found} = PartyRoles.revoke_role(company_fixture(), "customer")
    end

    test "is a no-op on an already-revoked role" do
      company = company_fixture()
      {:ok, _} = PartyRoles.grant_role(company, "customer")
      {:ok, revoked} = PartyRoles.revoke_role(company, "customer")

      assert {:ok, still_revoked} = PartyRoles.revoke_role(company, "customer")
      assert still_revoked.uuid == revoked.uuid
      refute still_revoked.is_active
    end

    test "logs the revoking activity with the given actor_uuid" do
      company = company_fixture()
      actor_uuid = Ecto.UUID.generate()
      {:ok, _} = PartyRoles.grant_role(company, "supplier")

      assert {:ok, _} = PartyRoles.revoke_role(company, "supplier", actor_uuid: actor_uuid)

      assert_activity_logged("crm.party_role_revoked",
        resource_uuid: company.uuid,
        actor_uuid: actor_uuid
      )
    end
  end

  describe "has_role?/2 and list_roles/1" do
    test "has_role? is false for inactive roles and other parties" do
      supplier = company_fixture(%{"name" => "Supplier Co"})
      other = company_fixture(%{"name" => "Other Co"})
      {:ok, _} = PartyRoles.grant_role(supplier, "supplier")

      assert PartyRoles.has_role?(supplier, "supplier")
      refute PartyRoles.has_role?(supplier, "customer")
      refute PartyRoles.has_role?(other, "supplier")
    end

    test "same-uuid roles are scoped by roleable_type" do
      company = company_fixture()
      contact = contact_fixture()
      {:ok, _} = PartyRoles.grant_role(company, "supplier")

      refute PartyRoles.has_role?(contact, "supplier")
    end
  end

  describe "list_companies_with_role/2 and list_contacts_with_role/2" do
    test "returns only active-role holders, name ascending" do
      zeta = company_fixture(%{"name" => "Zeta"})
      acme = company_fixture(%{"name" => "Acme"})
      _bystander = company_fixture(%{"name" => "Bystander"})
      {:ok, _} = PartyRoles.grant_role(zeta, "supplier")
      {:ok, _} = PartyRoles.grant_role(acme, "supplier")

      assert ["Acme", "Zeta"] =
               PartyRoles.list_companies_with_role("supplier") |> Enum.map(& &1.name)
    end

    test "excludes revoked roles unless include_inactive" do
      company = company_fixture()
      {:ok, _} = PartyRoles.grant_role(company, "customer")
      {:ok, _} = PartyRoles.revoke_role(company, "customer")

      assert PartyRoles.list_companies_with_role("customer") == []

      assert [%{uuid: uuid}] =
               PartyRoles.list_companies_with_role("customer", include_inactive: true)

      assert uuid == company.uuid
    end

    test "excludes trashed companies unless include_trashed" do
      company = company_fixture()
      {:ok, _} = PartyRoles.grant_role(company, "supplier")
      {:ok, _} = Companies.trash_company(company)

      assert PartyRoles.list_companies_with_role("supplier") == []
      assert [_] = PartyRoles.list_companies_with_role("supplier", include_trashed: true)
    end

    test "lists contacts with a role" do
      contact = contact_fixture()
      {:ok, _} = PartyRoles.grant_role(contact, "customer")

      assert [%{uuid: uuid}] = PartyRoles.list_contacts_with_role("customer")
      assert uuid == contact.uuid
    end

    test "list_contacts_with_role/2 paginates and searches within the role" do
      alice = contact_fixture(%{"name" => "Alice Wonder"})
      bob = contact_fixture(%{"name" => "Bob Wonder"})
      carol = contact_fixture(%{"name" => "Carol NotMatching"})

      {:ok, _} = PartyRoles.grant_role(alice, "supplier")
      {:ok, _} = PartyRoles.grant_role(bob, "supplier")
      {:ok, _} = PartyRoles.grant_role(carol, "supplier")

      assert PartyRoles.count_contacts_with_role("supplier") == 3

      page1 =
        PartyRoles.list_contacts_with_role("supplier", limit: 2, offset: 0)
        |> Enum.map(& &1.uuid)

      page2 =
        PartyRoles.list_contacts_with_role("supplier", limit: 2, offset: 2)
        |> Enum.map(& &1.uuid)

      assert length(page1) == 2
      assert page2 == [carol.uuid]

      searched = PartyRoles.list_contacts_with_role("supplier", search: "wonder")
      assert Enum.map(searched, & &1.uuid) |> Enum.sort() == Enum.sort([alice.uuid, bob.uuid])
      assert PartyRoles.count_contacts_with_role("supplier", search: "wonder") == 2
    end

    test "count_companies_with_role/2 honors the same filters as list_companies_with_role/2" do
      zeta = company_fixture(%{"name" => "Zeta"})
      acme = company_fixture(%{"name" => "Acme"})
      {:ok, _} = PartyRoles.grant_role(zeta, "customer")
      {:ok, _} = PartyRoles.grant_role(acme, "customer")

      assert PartyRoles.count_companies_with_role("customer") == 2
      assert PartyRoles.count_companies_with_role("customer", search: "zeta") == 1
    end
  end

  describe "get_supplier/1 (catalogue facade contract)" do
    test "hydrates a company with an active supplier role" do
      company =
        company_fixture(%{
          "name" => "Acme Supplies",
          "email" => "sales@acme.example",
          "phone" => "+372 555 0000",
          "website" => "https://acme.example"
        })

      {:ok, _} = PartyRoles.grant_role(company, "supplier")

      assert %{
               uuid: uuid,
               name: "Acme Supplies",
               email: "sales@acme.example",
               phone: "+372 555 0000",
               website: "https://acme.example",
               source: :crm
             } = PartyRoles.get_supplier(company.uuid)

      assert uuid == company.uuid
    end

    test "hydrates a contact supplier with website nil" do
      contact = contact_fixture(%{"name" => "Sole Trader", "email" => "st@ex.am"})
      {:ok, _} = PartyRoles.grant_role(contact, "supplier")

      assert %{name: "Sole Trader", website: nil, source: :crm} =
               PartyRoles.get_supplier(contact.uuid)
    end

    test "returns nil for non-suppliers, revoked suppliers, unknown and malformed uuids" do
      customer = company_fixture()
      {:ok, _} = PartyRoles.grant_role(customer, "customer")
      assert PartyRoles.get_supplier(customer.uuid) == nil

      revoked = company_fixture(%{"name" => "Ex Supplier"})
      {:ok, _} = PartyRoles.grant_role(revoked, "supplier")
      {:ok, _} = PartyRoles.revoke_role(revoked, "supplier")
      assert PartyRoles.get_supplier(revoked.uuid) == nil

      assert PartyRoles.get_supplier(Ecto.UUID.generate()) == nil
      assert PartyRoles.get_supplier("not-a-uuid") == nil
      assert PartyRoles.get_supplier(nil) == nil
    end
  end

  describe "active_roles_map/2 (list-page badge query)" do
    test "groups active roles by uuid and omits parties with none" do
      a = company_fixture(%{"name" => "A"})
      b = company_fixture(%{"name" => "B"})
      c = company_fixture(%{"name" => "C"})
      {:ok, _} = PartyRoles.grant_role(a, "supplier")
      {:ok, _} = PartyRoles.grant_role(a, "customer")
      {:ok, _} = PartyRoles.grant_role(b, "supplier")

      map = PartyRoles.active_roles_map("company", [a.uuid, b.uuid, c.uuid])
      assert Enum.sort(map[a.uuid]) == ["customer", "supplier"]
      assert map[b.uuid] == ["supplier"]
      refute Map.has_key?(map, c.uuid)
    end

    test "empty uuid list short-circuits to an empty map" do
      assert PartyRoles.active_roles_map("company", []) == %{}
    end

    test "omits revoked (inactive) roles" do
      a = company_fixture()
      {:ok, _} = PartyRoles.grant_role(a, "supplier")
      {:ok, _} = PartyRoles.revoke_role(a, "supplier")
      assert PartyRoles.active_roles_map("company", [a.uuid]) == %{}
    end

    test "is scoped by roleable_type (same uuid, different type)" do
      contact = contact_fixture()
      {:ok, _} = PartyRoles.grant_role(contact, "supplier")

      assert PartyRoles.active_roles_map("company", [contact.uuid]) == %{}
      assert PartyRoles.active_roles_map("contact", [contact.uuid])[contact.uuid] == ["supplier"]
    end
  end

  describe "grant_role/3 attribute safety" do
    test "a forged metadata attr is not castable and never persists" do
      company = company_fixture()

      {:ok, role} =
        PartyRoles.grant_role(company, "supplier", %{"metadata" => %{"injected" => true}})

      assert role.metadata == %{}
    end
  end

  describe "sync_roles/2 (form reconciliation)" do
    alias PhoenixKitCRM.Web.PartyRoleHelpers

    test "grants checked roles, revokes unchecked, returns :ok" do
      company = company_fixture()

      assert :ok = PartyRoleHelpers.sync_roles(company, ["supplier", "customer"])
      assert PartyRoles.has_role?(company, "supplier")
      assert PartyRoles.has_role?(company, "customer")

      assert :ok = PartyRoleHelpers.sync_roles(company, ["supplier"])
      assert PartyRoles.has_role?(company, "supplier")
      refute PartyRoles.has_role?(company, "customer")
    end

    test "threads actor_uuid into both the grant and the revoke activity log entries" do
      company = company_fixture()
      actor_uuid = Ecto.UUID.generate()

      assert :ok = PartyRoleHelpers.sync_roles(company, ["supplier", "customer"], actor_uuid)
      assert :ok = PartyRoleHelpers.sync_roles(company, ["supplier"], actor_uuid)

      assert_activity_logged("crm.party_role_granted",
        resource_uuid: company.uuid,
        actor_uuid: actor_uuid,
        metadata_has: %{"role" => "supplier"}
      )

      assert_activity_logged("crm.party_role_revoked",
        resource_uuid: company.uuid,
        actor_uuid: actor_uuid,
        metadata_has: %{"role" => "customer"}
      )
    end
  end
end
