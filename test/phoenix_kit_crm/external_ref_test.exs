defmodule PhoenixKitCRM.ExternalRefTest do
  @moduledoc """
  V11 external references on companies and contacts: what the changeset
  stores, the uniqueness per source, the CHECK behind "an id needs a
  source", and the lookups an importer uses.
  """
  use PhoenixKitCRM.DataCase, async: true

  alias PhoenixKitCRM.{Companies, Contacts}

  defp company!(attrs) do
    {:ok, company} = Companies.create_company(Map.merge(%{"name" => "Kraana OÜ"}, attrs))
    company
  end

  describe "companies" do
    test "a company without a reference stays as it was" do
      company = company!(%{})
      assert company.external_source == nil
      assert company.external_id == nil
    end

    test "the pair is trimmed, blank means none" do
      company = company!(%{"external_source" => " lab2 ", "external_id" => " 42 "})
      assert {company.external_source, company.external_id} == {"lab2", "42"}

      {:ok, cleared} =
        Companies.update_company(company, %{"external_source" => "", "external_id" => "  "})

      assert {cleared.external_source, cleared.external_id} == {nil, nil}
    end

    test "an id needs a source, in the changeset and in the database" do
      assert {:error, cs} = Companies.create_company(%{"name" => "X", "external_id" => "42"})
      assert cs.errors[:external_source]

      company = company!(%{})

      assert_raise Postgrex.Error, ~r/external_source_check/, fn ->
        Repo.query!(
          "UPDATE phoenix_kit_crm_companies SET external_id = '42' WHERE uuid = $1",
          [Ecto.UUID.dump!(company.uuid)]
        )
      end
    end

    test "an update from a stale struct that would break the CHECK is an error, not a raise" do
      company = company!(%{"external_source" => "lab2", "external_id" => "42"})

      # Someone else clears the reference meanwhile.
      {:ok, _} =
        Companies.update_company(company, %{"external_source" => "", "external_id" => ""})

      # The stale struct still says "lab2", so only the id is written.
      assert {:error, cs} =
               Companies.update_company(company, %{
                 "external_source" => "lab2",
                 "external_id" => "43"
               })

      assert cs.errors[:external_source]
    end

    test "an integer id is stored as its text and found by the same integer" do
      company = company!(%{"external_source" => "lab2", "external_id" => 42})
      assert company.external_id == "42"
      assert Companies.get_company_by_external_ref("lab2", 42).uuid == company.uuid

      assert %{"42" => %{uuid: uuid}} = Companies.map_companies_by_external_ids("lab2", [42])
      assert uuid == company.uuid
    end

    test "lengths count code points, as the varchar columns do" do
      # "e" + combining acute: one grapheme, two code points.
      decomposed = String.duplicate("e\u0301", 26)
      assert String.length(decomposed) == 26

      assert {:error, cs} =
               Companies.create_company(%{
                 "name" => "X",
                 "external_source" => decomposed,
                 "external_id" => "1"
               })

      assert cs.errors[:external_source]
    end

    test "the source is stored and looked up lowercase; case does not make a second source" do
      company = company!(%{"external_source" => " HubSpot ", "external_id" => "1"})
      assert company.external_source == "hubspot"
      assert Companies.get_company_by_external_ref("HUBSPOT", "1").uuid == company.uuid
      assert %{"1" => _} = Companies.map_companies_by_external_ids(" HubSpot", ["1"])

      assert {:error, cs} =
               Companies.create_company(%{
                 "name" => "Other",
                 "external_source" => "hubspot",
                 "external_id" => "1"
               })

      assert cs.errors[:external_id]
      assert Contacts.get_contact_by_external_ref("HubSpot", "1") == nil
    end

    test "the two messages are translated through the module's catalogue" do
      Gettext.with_locale(PhoenixKitCRM.Gettext, "et", fn ->
        assert {:error, cs} = Companies.create_company(%{"name" => "X", "external_id" => "1"})
        assert {"ei tohi olla tühi, kui väline ID on määratud", _} = cs.errors[:external_source]
      end)

      company!(%{"external_source" => "lab2", "external_id" => "9"})

      Gettext.with_locale(PhoenixKitCRM.Gettext, "ru", fn ->
        assert {:error, cs} =
                 Companies.create_company(%{
                   "name" => "Y",
                   "external_source" => "lab2",
                   "external_id" => "9"
                 })

        assert {"уже используется другой записью из этого источника (возможно, в корзине)", _} =
                 cs.errors[:external_id]
      end)
    end

    test "a pair is unique per source; the same id under another source is fine" do
      company!(%{"external_source" => "lab2", "external_id" => "42"})

      assert {:error, cs} =
               Companies.create_company(%{
                 "name" => "Other",
                 "external_source" => "lab2",
                 "external_id" => "42"
               })

      assert cs.errors[:external_id]

      assert {:ok, _} =
               Companies.create_company(%{
                 "name" => "Other",
                 "external_source" => "hubspot",
                 "external_id" => "42"
               })

      # Several companies without a reference never collide.
      company!(%{})
      company!(%{"external_source" => "lab2"})
      company!(%{"external_source" => "lab2"})
    end

    test "get_company_by_external_ref/2 finds it, trashed or not; blanks find nothing" do
      company = company!(%{"external_source" => "lab2", "external_id" => "42"})

      assert Companies.get_company_by_external_ref("lab2", "42").uuid == company.uuid
      assert Companies.get_company_by_external_ref(" lab2", 42).uuid == company.uuid
      assert Companies.get_company_by_external_ref("lab2", "43") == nil
      assert Companies.get_company_by_external_ref("hubspot", "42") == nil
      assert Companies.get_company_by_external_ref("", "42") == nil
      assert Companies.get_company_by_external_ref("lab2", nil) == nil

      {:ok, _} = Companies.trash_company(company)
      assert %{status: "trashed"} = Companies.get_company_by_external_ref("lab2", "42")
    end

    test "map_companies_by_external_ids/2 batches one source" do
      a = company!(%{"external_source" => "lab2", "external_id" => "1"})
      b = company!(%{"external_source" => "lab2", "external_id" => "2"})
      company!(%{"external_source" => "hubspot", "external_id" => "3"})

      result = Companies.map_companies_by_external_ids("lab2", [1, "2", "3", "", nil])
      assert Map.keys(result) |> Enum.sort() == ["1", "2"]
      assert result["1"].uuid == a.uuid
      assert result["2"].uuid == b.uuid
      assert Companies.map_companies_by_external_ids(nil, ["1"]) == %{}
      assert Companies.map_companies_by_external_ids("lab2", []) == %{}
    end
  end

  describe "contacts" do
    test "carry the same pair, unique per source, with the same lookups" do
      {:ok, mari} =
        Contacts.create_contact(%{
          "name" => "Mari",
          "external_source" => "lab2",
          "external_id" => "p-7"
        })

      assert {:error, cs} =
               Contacts.create_contact(%{
                 "name" => "Jüri",
                 "external_source" => "lab2",
                 "external_id" => "p-7"
               })

      assert cs.errors[:external_id]

      assert Contacts.get_contact_by_external_ref("lab2", "p-7").uuid == mari.uuid
      assert %{"p-7" => %{uuid: uuid}} = Contacts.map_contacts_by_external_ids("lab2", ["p-7"])
      assert uuid == mari.uuid
    end
  end

  test "the form labels are translated in et and ru" do
    for {locale, expected} <- [{"et", "Väline viide"}, {"ru", "Внешняя ссылка"}] do
      Gettext.with_locale(PhoenixKitCRM.Gettext, locale, fn ->
        assert Gettext.gettext(PhoenixKitCRM.Gettext, "External reference") == expected
      end)
    end
  end
end
