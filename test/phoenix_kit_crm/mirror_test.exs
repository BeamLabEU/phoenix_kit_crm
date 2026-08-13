defmodule PhoenixKitCRM.MirrorTest do
  @moduledoc """
  Pins the field-mapping + per-field divergence-diff engine shared by the
  Company↔organization-User and Contact↔person-User mirrors (owner
  decisions Q4/Q5): only fields present on BOTH sides participate in a
  diff, a blank side is filled by the copy without asking, and every
  genuine divergence surfaces per-field rather than an all-or-nothing
  overwrite.

  Pure logic — no DB, no context calls.
  """

  use ExUnit.Case, async: true

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitCRM.Mirror
  alias PhoenixKitCRM.Schemas.{Company, Contact}

  describe "field_map/1" do
    test "company maps name<->organization_name and email<->email" do
      map = Mirror.field_map(:company)

      assert %{crm: :name, user: :organization_name} =
               Enum.find(map, &(&1.crm == :name))

      assert %{crm: :email, user: :email} = Enum.find(map, &(&1.crm == :email))
    end

    test "contact maps name to the split first_name/last_name pair, and email<->email" do
      map = Mirror.field_map(:contact)

      assert %{crm: :name, user: {:split, :first_name, :last_name}} =
               Enum.find(map, &(&1.crm == :name))

      assert %{crm: :email, user: :email} = Enum.find(map, &(&1.crm == :email))
    end
  end

  describe "diff/2 — company" do
    test "reports a field present on both sides and differing" do
      company = %Company{name: "Acme", email: "a@acme.test"}

      user = %User{
        organization_name: "Acme GmbH",
        email: "a@acme.test",
        account_type: "organization"
      }

      assert [%{field: :organization_name, crm: "Acme", user: "Acme GmbH"}] =
               Mirror.diff(company, user)
    end

    test "reports nothing when every mapped field agrees" do
      company = %Company{name: "Acme", email: "a@acme.test"}
      user = %User{organization_name: "Acme", email: "a@acme.test", account_type: "organization"}

      assert Mirror.diff(company, user) == []
    end

    test "a blank on either side is not a conflict — the copy fills it, no ask" do
      company = %Company{name: "Acme", email: "a@acme.test"}
      user = %User{organization_name: nil, email: "", account_type: "organization"}

      assert Mirror.diff(company, user) == []
    end

    test "every mapped field can diverge independently" do
      company = %Company{name: "Acme", email: "a@acme.test"}

      user = %User{
        organization_name: "Acme GmbH",
        email: "b@acme.test",
        account_type: "organization"
      }

      diff = Mirror.diff(company, user)
      fields = Enum.map(diff, & &1.field) |> Enum.sort()

      assert fields == [:email, :organization_name]
    end
  end

  describe "diff/2 — contact" do
    test "reports the joined user name vs contact.name when they differ" do
      contact = %Contact{name: "Anna Kask", email: "anna@example.test"}
      user = %User{first_name: "Anna", last_name: "K.", email: "anna@example.test"}

      assert [%{field: :name, crm: "Anna Kask", user: "Anna K."}] = Mirror.diff(contact, user)
    end

    test "reports nothing when the joined name matches" do
      contact = %Contact{name: "Anna Kask", email: "anna@example.test"}
      user = %User{first_name: "Anna", last_name: "Kask", email: "anna@example.test"}

      assert Mirror.diff(contact, user) == []
    end

    test "a fully blank user name is not a conflict" do
      contact = %Contact{name: "Anna Kask", email: "anna@example.test"}
      user = %User{first_name: nil, last_name: nil, email: "anna@example.test"}

      assert Mirror.diff(contact, user) == []
    end
  end

  describe "name join (User -> CRM, attrs_to_crm/2)" do
    test "joins first_name and last_name with a space" do
      user = %User{first_name: "Anna", last_name: "Kask", email: "anna@example.test"}

      assert Mirror.attrs_to_crm(:contact, user).name == "Anna Kask"
    end

    test "trims when one side is blank" do
      assert Mirror.attrs_to_crm(:contact, %User{first_name: "Anna", last_name: nil}).name ==
               "Anna"

      assert Mirror.attrs_to_crm(:contact, %User{first_name: nil, last_name: "Kask"}).name ==
               "Kask"
    end

    test "is nil when both sides are blank" do
      assert Mirror.attrs_to_crm(:contact, %User{first_name: nil, last_name: nil}).name == nil
      assert Mirror.attrs_to_crm(:contact, %User{first_name: "", last_name: ""}).name == nil
    end

    test "carries email through unchanged" do
      assert Mirror.attrs_to_crm(:contact, %User{email: "a@b.test"}).email == "a@b.test"
    end
  end

  describe "attrs_to_crm/2 — company" do
    test "organization_name becomes name, email carries through" do
      user = %User{organization_name: "Acme GmbH", email: "a@acme.test"}

      assert Mirror.attrs_to_crm(:company, user) == %{name: "Acme GmbH", email: "a@acme.test"}
    end
  end

  describe "name split (CRM -> User, attrs_from/2)" do
    test "two tokens: everything before the last space is first_name, the last token is last_name" do
      attrs = Mirror.attrs_from(:contact, %Contact{name: "Anna Kask", email: "a@b.test"})

      assert attrs.first_name == "Anna"
      assert attrs.last_name == "Kask"
    end

    test "three or more tokens: last token is last_name, the rest join as first_name" do
      attrs = Mirror.attrs_from(:contact, %Contact{name: "Anna Marie Kask"})

      assert attrs.first_name == "Anna Marie"
      assert attrs.last_name == "Kask"
    end

    test "a single token sets first_name and leaves last_name nil" do
      attrs = Mirror.attrs_from(:contact, %Contact{name: "Bob"})

      assert attrs.first_name == "Bob"
      assert attrs.last_name == nil
    end

    test "a blank name yields nil for both" do
      assert %{first_name: nil, last_name: nil} = Mirror.attrs_from(:contact, %Contact{name: nil})
      assert %{first_name: nil, last_name: nil} = Mirror.attrs_from(:contact, %Contact{name: ""})
    end

    test "sets account_type person and carries email" do
      attrs = Mirror.attrs_from(:contact, %Contact{name: "Bob", email: "bob@example.test"})

      assert attrs.account_type == "person"
      assert attrs.email == "bob@example.test"
    end
  end

  describe "attrs_from/2 — company" do
    test "sets account_type organization, organization_name, and email" do
      attrs = Mirror.attrs_from(:company, %Company{name: "Acme", email: "a@acme.test"})

      assert attrs == %{
               account_type: "organization",
               organization_name: "Acme",
               email: "a@acme.test"
             }
    end
  end
end
