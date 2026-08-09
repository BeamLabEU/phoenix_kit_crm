defmodule PhoenixKitCRM.CompaniesTest do
  use PhoenixKitCRM.DataCase, async: true

  alias PhoenixKitCRM.{Companies, Contacts}
  alias PhoenixKitCRM.Schemas.Company

  defp company_fixture(attrs \\ %{}) do
    {:ok, company} = Companies.create_company(Map.merge(%{"name" => "Test Co"}, attrs))
    company
  end

  defp contact_fixture(name) do
    {:ok, contact} = Contacts.create_contact(%{"name" => name})
    contact
  end

  describe "create_company/1" do
    test "creates an active company from a name" do
      assert {:ok, %Company{} = c} = Companies.create_company(%{"name" => "Acme"})
      assert c.name == "Acme"
      assert c.status == "active"
    end

    test "requires a name" do
      assert {:error, cs} = Companies.create_company(%{"name" => ""})
      assert cs.errors[:name]
    end

    test "rejects an invalid status" do
      assert {:error, cs} = Companies.create_company(%{"name" => "X", "status" => "nope"})
      assert cs.errors[:status]
    end
  end

  describe "get_company/1" do
    test "returns by uuid; nil for unknown or malformed" do
      c = company_fixture()
      assert Companies.get_company(c.uuid).uuid == c.uuid
      assert Companies.get_company(Ecto.UUID.generate()) == nil
      assert Companies.get_company("nope") == nil
    end
  end

  describe "update_company/2" do
    test "updates editable fields" do
      c = company_fixture()
      assert {:ok, updated} = Companies.update_company(c, %{"industry" => "Tech"})
      assert updated.industry == "Tech"
    end
  end

  describe "trash_company/1 + restore_company/1" do
    test "trash sets the sentinel status and stashes the prior one" do
      assert {:ok, trashed} = Companies.trash_company(company_fixture())
      assert trashed.status == "trashed"
      assert trashed.metadata["trashed_from_status"] == "active"
    end

    test "trashing an already-trashed company errors" do
      {:ok, trashed} = Companies.trash_company(company_fixture())
      assert {:error, :already_trashed} = Companies.trash_company(trashed)
    end

    test "restore reverses the trash and clears the stash" do
      {:ok, trashed} = Companies.trash_company(company_fixture())
      assert {:ok, restored} = Companies.restore_company(trashed)
      assert restored.status == "active"
      refute Map.has_key?(restored.metadata, "trashed_from_status")
    end

    test "restoring a non-trashed company errors" do
      assert {:error, :not_trashed} = Companies.restore_company(company_fixture())
    end
  end

  describe "list_companies/1 + count_companies/1" do
    test "active list excludes trashed; trashed filter is the inverse" do
      active = company_fixture(%{"name" => "Active Co"})
      {:ok, trashed} = Companies.trash_company(company_fixture(%{"name" => "Trashed Co"}))

      active_uuids = Companies.list_companies() |> Enum.map(& &1.uuid)
      assert active.uuid in active_uuids
      refute trashed.uuid in active_uuids

      trashed_uuids = Companies.list_companies(status: "trashed") |> Enum.map(& &1.uuid)
      assert trashed.uuid in trashed_uuids
      refute active.uuid in trashed_uuids
    end

    test "count_companies honors the status filter" do
      {:ok, _} = Companies.trash_company(company_fixture())
      assert Companies.count_companies(status: "trashed") == 1
    end

    test "escapes LIKE wildcards so % and _ match literally, not everything" do
      pct = company_fixture(%{"name" => "50% Off Co"})
      underscore = company_fixture(%{"name" => "under_score Co"})
      plain = company_fixture(%{"name" => "Plain Co"})

      pct_uuids = Companies.list_companies(search: "%") |> Enum.map(& &1.uuid)
      assert pct.uuid in pct_uuids
      refute plain.uuid in pct_uuids
      refute underscore.uuid in pct_uuids

      underscore_uuids = Companies.list_companies(search: "_") |> Enum.map(& &1.uuid)
      assert underscore.uuid in underscore_uuids
      refute plain.uuid in underscore_uuids
      refute pct.uuid in underscore_uuids
    end
  end

  describe "list_memberships/1" do
    test "excludes memberships whose contact is trashed" do
      company = company_fixture(%{"name" => "Roster Co"})
      active = contact_fixture("Active Member")
      gone = contact_fixture("Gone Member")
      {:ok, _} = Contacts.set_primary_company(active, company.uuid, "Eng", nil)
      {:ok, _} = Contacts.set_primary_company(gone, company.uuid, "Eng", nil)

      {:ok, _} = Contacts.trash_contact(gone)

      member_uuids = company.uuid |> Companies.list_memberships() |> Enum.map(& &1.contact_uuid)
      assert active.uuid in member_uuids
      refute gone.uuid in member_uuids
    end
  end

  describe "list_by_uuids/1" do
    test "returns the companies for the given uuids; [] for empty input" do
      a = company_fixture(%{"name" => "A"})
      b = company_fixture(%{"name" => "B"})
      uuids = [a.uuid, b.uuid] |> Companies.list_by_uuids() |> Enum.map(& &1.uuid)
      assert a.uuid in uuids and b.uuid in uuids
      assert Companies.list_by_uuids([]) == []
    end

    test "drops malformed uuids instead of raising" do
      a = company_fixture(%{"name" => "Valid Co"})

      assert ["not-a-uuid", a.uuid] |> Companies.list_by_uuids() |> Enum.map(& &1.uuid) == [
               a.uuid
             ]

      assert Companies.list_by_uuids(["also-bad"]) == []
    end
  end

  describe "search_companies/2" do
    test "matches by name and excludes trashed" do
      hit = company_fixture(%{"name" => "Searchable Inc"})
      {:ok, trashed} = Companies.trash_company(company_fixture(%{"name" => "Searchable Gone"}))

      uuids = "Searchable" |> Companies.search_companies() |> Enum.map(& &1.uuid)
      assert hit.uuid in uuids
      refute trashed.uuid in uuids
    end

    test "escapes LIKE wildcards so % matches literally, not everything" do
      pct = company_fixture(%{"name" => "100% Cotton"})
      plain = company_fixture(%{"name" => "Plain Cotton"})

      # Unescaped, "%" would be a wildcard matching every company.
      uuids = "%" |> Companies.search_companies() |> Enum.map(& &1.uuid)
      assert pct.uuid in uuids
      refute plain.uuid in uuids
    end

    test "tolerates a null byte in the query (no Postgres crash)" do
      hit = company_fixture(%{"name" => "Nullsafe Co"})
      uuids = "Null\x00safe" |> Companies.search_companies() |> Enum.map(& &1.uuid)
      assert hit.uuid in uuids
    end
  end
end
