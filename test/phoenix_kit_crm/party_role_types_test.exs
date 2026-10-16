defmodule PhoenixKitCRM.PartyRoleTypesTest do
  use PhoenixKitCRM.DataCase, async: true

  import PhoenixKitCRM.ActivityLogAssertions

  alias PhoenixKitCRM.{Companies, PartyRoles, PartyRoleTypes}
  alias PhoenixKitCRM.Schemas.PartyRoleType

  defp carrier_attrs(extra \\ %{}) do
    Map.merge(
      %{"key" => "carrier", "data" => PartyRoleTypes.build_data("Carrier")},
      extra
    )
  end

  defp company_fixture do
    {:ok, company} = Companies.create_company(%{"name" => "Fast Freight"})
    company
  end

  describe "the seeded built-ins" do
    test "are the four roles, in the overview's order, all active" do
      builtins = Enum.filter(PartyRoleTypes.list_types(), & &1.builtin)

      assert Enum.map(builtins, & &1.key) == ~w(supplier manufacturer customer partner)
      assert Enum.all?(builtins, &(&1.status == "active"))
    end

    test "name falls back to the gettext string, plural_name to the gettext plural" do
      types = PartyRoleTypes.types_by_key()

      assert PartyRoleTypes.name(types["supplier"]) == "Supplier"
      assert PartyRoleTypes.plural_name(types, "supplier") == "Suppliers"
      assert PartyRoleTypes.badge_class(types, "supplier") == "badge-info"
      assert PartyRoleTypes.icon(types, "supplier") == "hero-truck"
    end

    test "can be relabelled; the tab plural then follows the new name" do
      supplier = PartyRoleTypes.get_type_by_key("supplier")

      assert {:ok, updated} =
               PartyRoleTypes.update_type(supplier, %{
                 "data" => PartyRoleTypes.build_data("Vendor")
               })

      types = %{"supplier" => updated}
      assert PartyRoleTypes.label(types, "supplier") == "Vendor"
      assert PartyRoleTypes.plural_name(types, "supplier") == "Vendor"
    end

    test "cannot be archived or deleted, and the key cannot change" do
      supplier = PartyRoleTypes.get_type_by_key("supplier")

      assert {:error, cs} = PartyRoleTypes.archive_type(supplier)
      assert cs.errors[:status]

      assert {:error, :builtin} = PartyRoleTypes.delete_type(supplier)

      assert {:ok, same} = PartyRoleTypes.update_type(supplier, %{"key" => "vendor"})
      assert same.key == "supplier"
    end
  end

  describe "create_type/2" do
    test "creates a custom type at the end of the list and logs it" do
      actor = Ecto.UUID.generate()
      assert {:ok, type} = PartyRoleTypes.create_type(carrier_attrs(), actor_uuid: actor)

      assert type.key == "carrier"
      refute type.builtin
      assert type.status == "active"
      assert List.last(PartyRoleTypes.list_types()).key == "carrier"
      assert type.position > Enum.max(for t <- PartyRoleTypes.list_types(), do: t.position) - 1

      assert_activity_logged("crm.party_role_type_created",
        actor_uuid: actor,
        resource_uuid: type.uuid,
        metadata: %{"key" => "carrier"}
      )
    end

    test "builtin cannot be set by the caller" do
      assert {:ok, type} = PartyRoleTypes.create_type(carrier_attrs(%{"builtin" => true}))
      refute type.builtin
    end

    test "validates the key: format, length, reserved words, uniqueness" do
      for bad <- [
            "Carrier",
            "1carrier",
            "car rier",
            "car-rier",
            "a" <> String.duplicate("b", 30)
          ] do
        assert {:error, cs} = PartyRoleTypes.create_type(carrier_attrs(%{"key" => bad}))
        assert cs.errors[:key], "expected #{inspect(bad)} to be rejected"
      end

      for reserved <- ~w(all active inactive trashed) do
        assert {:error, cs} = PartyRoleTypes.create_type(carrier_attrs(%{"key" => reserved}))
        assert {"is reserved", _} = cs.errors[:key]
      end

      assert {:ok, _} =
               PartyRoleTypes.create_type(carrier_attrs(%{"key" => String.duplicate("a", 30)}))

      assert {:ok, _} = PartyRoleTypes.create_type(carrier_attrs())
      assert {:error, cs} = PartyRoleTypes.create_type(carrier_attrs())
      assert {"is already taken", _} = cs.errors[:key]
    end

    test "a missing key is derived from the name; a name with no Latin letters needs one given" do
      assert {:ok, type} =
               PartyRoleTypes.create_type(%{
                 "data" => PartyRoleTypes.build_data("Freight forwarder")
               })

      assert type.key == "freight_forwarder"

      assert {:error, cs} =
               PartyRoleTypes.create_type(%{"data" => PartyRoleTypes.build_data("Перевозчик")})

      assert cs.errors[:key]

      assert {:ok, %{key: "vedaja"}} =
               PartyRoleTypes.create_type(%{
                 "key" => "vedaja",
                 "data" => PartyRoleTypes.build_data("Перевозчик")
               })
    end

    test "the form's plain name / description fields fold into data under the primary language" do
      assert {:ok, type} =
               PartyRoleTypes.create_type(%{"name" => "Installer", "description" => "Fits it"})

      assert type.key == "installer"
      assert PartyRoleTypes.name(type) == "Installer"
      assert PartyRoleTypes.description(type) == "Fits it"
      assert PartyRoleTypes.hydrate(type).name == "Installer"
    end

    test "a custom type needs a name, and badge / icon come from the short lists" do
      assert {:error, cs} = PartyRoleTypes.create_type(%{"key" => "carrier"})
      assert cs.errors[:name]

      assert {:error, cs} = PartyRoleTypes.create_type(carrier_attrs(%{"badge" => "badge-evil"}))
      assert cs.errors[:badge]

      assert {:error, cs} = PartyRoleTypes.create_type(carrier_attrs(%{"icon" => "hero-nope"}))
      assert cs.errors[:icon]

      assert {:error, cs} =
               PartyRoleTypes.create_type(carrier_attrs(%{"data" => "just a string"}))

      assert cs.errors[:data]
    end

    test "malformed translations return data errors instead of crashing readers" do
      for data <- [
            %{"_primary_language" => 42},
            %{"_primary_language" => "en", "en" => "Carrier"},
            %{"_primary_language" => "en", "en" => %{"_name" => "Carrier"}, "et" => []},
            %{"_primary_language" => "en", "en" => %{"_name" => ["Carrier"]}}
          ] do
        assert {:error, cs} = PartyRoleTypes.create_type(carrier_attrs(%{"data" => data}))
        assert cs.errors[:data]
      end
    end
  end

  describe "update_type/3" do
    test "plain field edits preserve the other primary fields and translations" do
      {:ok, type} =
        PartyRoleTypes.ensure("carrier",
          names: %{"en" => "Carrier", "et" => "Vedaja"},
          descriptions: %{"en" => "Moves goods", "et" => "Veab kaupu"}
        )

      assert {:ok, updated} = PartyRoleTypes.update_type(type, %{"name" => "Hauler"})
      assert PartyRoleTypes.name(updated, "en") == "Hauler"
      assert PartyRoleTypes.description(updated, "en") == "Moves goods"
      assert PartyRoleTypes.name(updated, "et") == "Vedaja"
      assert PartyRoleTypes.description(updated, "et") == "Veab kaupu"

      assert {:ok, updated} =
               PartyRoleTypes.update_type(updated, %{"description" => "Delivers goods"})

      assert PartyRoleTypes.name(updated, "en") == "Hauler"
      assert PartyRoleTypes.description(updated, "en") == "Delivers goods"
    end

    test "required persisted fields return changeset errors when cleared" do
      {:ok, type} = PartyRoleTypes.create_type(carrier_attrs())

      for field <- ~w(badge icon status position data) do
        assert {:error, cs} = PartyRoleTypes.update_type(type, %{field => nil})
        assert cs.errors[String.to_existing_atom(field)]
      end
    end

    test "relabels, restyles and never touches the key" do
      {:ok, type} = PartyRoleTypes.create_type(carrier_attrs())

      assert {:ok, updated} =
               PartyRoleTypes.update_type(type, %{
                 "key" => "hauler",
                 "badge" => "badge-secondary",
                 "icon" => "hero-truck",
                 "data" => PartyRoleTypes.build_data(%{"en" => "Hauler"})
               })

      assert updated.key == "carrier"
      assert updated.badge == "badge-secondary"
      assert PartyRoleTypes.name(updated, "en") == "Hauler"
    end
  end

  describe "archive_type/2 and restore_type/2" do
    test "an archived type is no longer active but stays listed and resolvable" do
      {:ok, type} = PartyRoleTypes.create_type(carrier_attrs())
      assert PartyRoleTypes.active?("carrier")

      assert {:ok, archived} = PartyRoleTypes.archive_type(type)
      assert archived.status == "archived"
      refute PartyRoleTypes.active?("carrier")
      refute "carrier" in PartyRoleTypes.active_keys()
      assert "carrier" in Map.keys(PartyRoleTypes.types_by_key())
      assert [%{key: "carrier"}] = PartyRoleTypes.list_types(status: :archived)

      assert {:ok, restored} = PartyRoleTypes.restore_type(archived)
      assert restored.status == "active"
      assert PartyRoleTypes.active?("carrier")
    end
  end

  describe "delete_type/2" do
    test "deletes a custom type nobody holds" do
      {:ok, type} = PartyRoleTypes.create_type(carrier_attrs())

      assert {:ok, _} = PartyRoleTypes.delete_type(type)
      refute PartyRoleTypes.get_type_by_key("carrier")
      assert_activity_logged("crm.party_role_type_deleted", resource_uuid: type.uuid)
    end

    test "refuses a type in use -- even one whose holder was revoked -- and the FK agrees" do
      {:ok, type} = PartyRoleTypes.create_type(carrier_attrs())
      company = company_fixture()
      {:ok, _} = PartyRoles.grant_role(company, "carrier")

      assert {:error, :in_use} = PartyRoleTypes.delete_type(type)

      {:ok, _} = PartyRoles.revoke_role(company, "carrier")
      assert {:error, :in_use} = PartyRoleTypes.delete_type(type)

      # Bypassing the context's pre-check, the database says no as well.
      assert_raise Postgrex.Error, ~r/phoenix_kit_crm_party_roles_role_fkey/, fn ->
        Repo.delete_all(from(t in PartyRoleType, where: t.key == "carrier"))
      end
    end

    test "the key of a type in use cannot be rewritten under its assignments" do
      {:ok, _} = PartyRoleTypes.create_type(carrier_attrs())
      {:ok, _} = PartyRoles.grant_role(company_fixture(), "carrier")

      assert_raise Postgrex.Error, ~r/phoenix_kit_crm_party_roles_role_fkey/, fn ->
        Repo.update_all(from(t in PartyRoleType, where: t.key == "carrier"), set: [key: "hauler"])
      end
    end
  end

  describe "reorder/2" do
    test "the list order is the new position order" do
      {:ok, carrier} = PartyRoleTypes.create_type(carrier_attrs())
      partner = PartyRoleTypes.get_type_by_key("partner")
      supplier = PartyRoleTypes.get_type_by_key("supplier")

      rest =
        PartyRoleTypes.list_types()
        |> Enum.reject(&(&1.key in ["carrier", "partner", "supplier"]))
        |> Enum.map(& &1.uuid)

      assert :ok =
               PartyRoleTypes.reorder(
                 [carrier.uuid, partner.uuid, supplier.uuid, "not-a-uuid"] ++ rest
               )

      keys = PartyRoleTypes.list_types() |> Enum.map(& &1.key)
      assert Enum.take(keys, 3) == ["carrier", "partner", "supplier"]
    end
  end

  describe "ensure/3" do
    test "creates the type with its translations, once" do
      assert {:ok, type} =
               PartyRoleTypes.ensure("carrier",
                 names: %{"en" => "Carrier", "et" => "Vedaja", "ru" => "Перевозчик"},
                 badge: "badge-secondary",
                 icon: "hero-truck"
               )

      assert type.badge == "badge-secondary"
      assert PartyRoleTypes.name(type, "et") == "Vedaja"
      assert PartyRoleTypes.name(type, "ru") == "Перевозчик"
      assert PartyRoleTypes.name(type, "en") == "Carrier"

      assert {:ok, again} = PartyRoleTypes.ensure("carrier", name: "Something else")
      assert again.uuid == type.uuid
      assert PartyRoleTypes.name(again, "en") == "Carrier"
    end

    test "never overwrites an admin's edit or resurrects an archived type" do
      {:ok, type} = PartyRoleTypes.ensure("carrier", name: "Carrier")
      {:ok, _} = PartyRoleTypes.archive_type(type)

      assert {:ok, still} = PartyRoleTypes.ensure("carrier", name: "Carrier")
      assert still.status == "archived"
    end

    test "a bad key or a missing name is an error, not a raise" do
      assert {:error, cs} = PartyRoleTypes.ensure("Bad Key", name: "X")
      assert cs.errors[:key]

      assert {:error, cs} = PartyRoleTypes.ensure("nameless")
      assert cs.errors[:name]
    end

    test "ensure/3 on a built-in key returns the built-in" do
      assert {:ok, %{builtin: true, key: "supplier"}} =
               PartyRoleTypes.ensure("supplier", name: "X")
    end
  end

  describe "display" do
    test "a translation falls back to the primary language, then the key" do
      {:ok, type} =
        PartyRoleTypes.create_type(
          carrier_attrs(%{
            "data" => PartyRoleTypes.build_data(%{"en" => "Carrier", "et" => "Vedaja"})
          })
        )

      assert PartyRoleTypes.name(type, "et") == "Vedaja"
      assert PartyRoleTypes.name(type, "fr") == "Carrier"
      assert PartyRoleTypes.label(%{}, "carrier") == "carrier"
      assert PartyRoleTypes.label(nil, "supplier") == "Supplier"
    end

    test "build_data drops blanks and trims" do
      data =
        PartyRoleTypes.build_data(%{"en" => " Carrier ", "et" => "  "}, %{"en" => "Moves goods"})

      assert get_in(data, ["en", "_name"]) == "Carrier"
      assert get_in(data, ["en", "_description"]) == "Moves goods"
      refute Map.has_key?(data, "et")
      assert PartyRoleTypes.build_data(nil) == %{}
    end

    test "derive_key" do
      assert PartyRoleTypes.derive_key("Carrier") == "carrier"
      assert PartyRoleTypes.derive_key("Freight forwarder") == "freight_forwarder"
      assert PartyRoleTypes.derive_key("Vedaja Õ") == "vedaja_o"
      assert PartyRoleTypes.derive_key("3PL partner") == "pl_partner"
      assert PartyRoleTypes.derive_key("Перевозчик") == ""
      assert PartyRoleTypes.derive_key(nil) == ""
      assert String.length(PartyRoleTypes.derive_key(String.duplicate("word ", 20))) <= 30
    end
  end
end
