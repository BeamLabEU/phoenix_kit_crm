defmodule PhoenixKitCRM.CompaniesMirrorTest do
  @moduledoc """
  Pins the Company <-> organization-User mirror context (owner decision
  Q3: organization-type users ONLY, no membership/organization_uuid
  propagation). Every fixture here is a REAL persisted row — the
  pre-existing `ContactsTest.map_by_user_uuids/1` bug (linking to a random
  `Ecto.UUID.generate()` with no backing user row) is exactly the mistake
  this suite avoids.
  """

  use PhoenixKitCRM.DataCase, async: true

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitCRM.Companies
  alias PhoenixKitCRM.Schemas.Company

  defp unique, do: System.unique_integer([:positive])

  defp org_user_fixture(attrs \\ %{}) do
    base = %{
      "email" => "org-#{unique()}@example.test",
      "password" => "Sup3rSecret!24",
      "account_type" => "organization",
      "organization_name" => "Acme"
    }

    {:ok, user} = Auth.register_user(Map.merge(base, attrs))
    user
  end

  defp person_user_fixture(attrs \\ %{}) do
    base = %{"email" => "person-#{unique()}@example.test", "password" => "Sup3rSecret!24"}
    {:ok, user} = Auth.register_user(Map.merge(base, attrs))
    user
  end

  defp company_fixture(attrs \\ %{}) do
    {:ok, company} = Companies.create_company(Map.merge(%{"name" => "Acme"}, attrs))
    company
  end

  describe "get_by_user_uuid/1" do
    test "nil for nil and for a malformed uuid (no cast error)" do
      assert Companies.get_by_user_uuid(nil) == nil
      assert Companies.get_by_user_uuid("not-a-uuid") == nil
    end

    test "nil when no company is linked to the user" do
      user = org_user_fixture()
      assert Companies.get_by_user_uuid(user.uuid) == nil
    end

    test "returns the linked company" do
      company = company_fixture()
      user = org_user_fixture()
      {:ok, linked} = Companies.connect_user(company, user.uuid)

      assert Companies.get_by_user_uuid(user.uuid).uuid == linked.uuid
    end
  end

  describe "connect_user/2" do
    test "links an existing organization user; sets company.user_uuid" do
      company = company_fixture()
      user = org_user_fixture()

      assert {:ok, linked} = Companies.connect_user(company, user.uuid)
      assert linked.user_uuid == user.uuid
      assert Companies.get_company(company.uuid).user_uuid == user.uuid
    end

    test "rejects a person user; company unchanged" do
      company = company_fixture()
      user = person_user_fixture()

      assert {:error, :not_an_organization} = Companies.connect_user(company, user.uuid)
      refute Companies.get_company(company.uuid).user_uuid
    end

    test "rejects a uuid with no backing user row" do
      company = company_fixture()

      assert {:error, :user_not_found} = Companies.connect_user(company, Ecto.UUID.generate())
      refute Companies.get_company(company.uuid).user_uuid
    end

    test "rejects a user already linked to another company — no crash" do
      user = org_user_fixture()
      first = company_fixture(%{"name" => "First"})
      second = company_fixture(%{"name" => "Second"})

      assert {:ok, _} = Companies.connect_user(first, user.uuid)
      assert {:error, %Ecto.Changeset{}} = Companies.connect_user(second, user.uuid)

      refute Companies.get_company(second.uuid).user_uuid
      assert Companies.get_company(first.uuid).user_uuid == user.uuid
    end

    test "re-linking an already-linked company to a different user is a safe relink" do
      company = company_fixture()
      user_a = org_user_fixture()
      user_b = org_user_fixture()

      {:ok, _} = Companies.connect_user(company, user_a.uuid)
      assert {:ok, relinked} = Companies.connect_user(company, user_b.uuid)
      assert relinked.user_uuid == user_b.uuid
    end
  end

  describe "disconnect_user/1" do
    test "clears user_uuid; leaves the user row intact" do
      company = company_fixture()
      user = org_user_fixture()
      {:ok, linked} = Companies.connect_user(company, user.uuid)

      assert {:ok, disconnected} = Companies.disconnect_user(linked)
      assert disconnected.user_uuid == nil
      assert Auth.get_user(user.uuid) != nil
    end

    test "safe no-op on an already-unlinked company" do
      company = company_fixture()
      assert {:ok, unchanged} = Companies.disconnect_user(company)
      assert unchanged.user_uuid == nil
    end
  end

  describe "create_mirror_user/2" do
    test "creates an organization user from the company and links it atomically" do
      company =
        company_fixture(%{"name" => "Acme", "email" => "acme-mirror-#{unique()}@example.test"})

      assert {:ok, {linked, user}} = Companies.create_mirror_user(company)

      assert linked.user_uuid == user.uuid
      assert user.account_type == "organization"
      assert user.organization_name == "Acme"
      assert user.email == company.email
      assert user.custom_fields["source"] == "crm_company"
      assert Companies.get_company(company.uuid).user_uuid == user.uuid
    end

    test "on a forced link failure inside the transaction, the created user is rolled back" do
      # A company struct with a uuid the DB has never seen makes the
      # `Repo.update` inside connect_user fail hard (Ecto.StaleEntryError)
      # rather than returning a clean {:error, changeset} — a sharper
      # failure than the codebase can otherwise provoke on demand (a
      # freshly-registered user's uuid can never already collide with
      # idx_crm_companies_user_uuid), but it exercises the same guarantee
      # under test: nothing partial survives a failed link.
      email = "ghost-mirror-#{unique()}@example.test"
      ghost_company = %Company{uuid: Ecto.UUID.generate(), name: "Ghost", email: email}

      assert_raise Ecto.StaleEntryError, fn ->
        Companies.create_mirror_user(ghost_company)
      end

      refute Auth.get_user_by_email(email)
    end

    test "rejects when the company already has a mirror user — no new user is minted" do
      company = company_fixture()
      original_user = org_user_fixture()
      {:ok, linked} = Companies.connect_user(company, original_user.uuid)

      assert {:error, :already_linked} = Companies.create_mirror_user(linked)

      # The original link survives untouched — no relink, no orphan.
      assert Companies.get_company(company.uuid).user_uuid == original_user.uuid
    end

    test "when Auth.register_user fails (duplicate email), the transaction rolls back cleanly — exercises the explicit repo().rollback/1 branch, not just Ecto's exception rollback" do
      taken_email = "taken-#{unique()}@example.test"
      _existing = person_user_fixture(%{"email" => taken_email})
      company = company_fixture(%{"name" => "Acme", "email" => taken_email})

      assert {:error, %Ecto.Changeset{}} = Companies.create_mirror_user(company)
      refute Companies.get_company(company.uuid).user_uuid
    end
  end

  describe "create_from_user/1" do
    test "adopts an existing unlinked company by name" do
      company = company_fixture(%{"name" => "Acme"})
      user = org_user_fixture(%{"organization_name" => "Acme"})

      assert {:ok, adopted} = Companies.create_from_user(user)
      assert adopted.uuid == company.uuid
      assert adopted.user_uuid == user.uuid
    end

    test "falls back to matching by email when no name match exists" do
      shared_email = "shared-#{unique()}@example.test"
      company = company_fixture(%{"name" => "Different Name", "email" => shared_email})
      user = org_user_fixture(%{"organization_name" => "No Match", "email" => shared_email})

      assert {:ok, adopted} = Companies.create_from_user(user)
      assert adopted.uuid == company.uuid
    end

    test "prefers a name match over an email match" do
      shared_email = "shared2-#{unique()}@example.test"
      by_name = company_fixture(%{"name" => "Acme", "email" => "other-#{unique()}@example.test"})
      _by_email = company_fixture(%{"name" => "Different", "email" => shared_email})

      user = org_user_fixture(%{"organization_name" => "Acme", "email" => shared_email})

      assert {:ok, adopted} = Companies.create_from_user(user)
      assert adopted.uuid == by_name.uuid
    end

    test "does not adopt a company already linked to a different user" do
      other_user = org_user_fixture(%{"organization_name" => "Other"})
      linked_company = company_fixture(%{"name" => "Acme"})
      {:ok, _} = Companies.connect_user(linked_company, other_user.uuid)

      user =
        org_user_fixture(%{
          "organization_name" => "Acme",
          "email" => "fresh-#{unique()}@example.test"
        })

      assert {:ok, created} = Companies.create_from_user(user)
      refute created.uuid == linked_company.uuid
      assert created.user_uuid == user.uuid
    end

    test "creates a new company when no unlinked match exists" do
      user =
        org_user_fixture(%{
          "organization_name" => "Globex #{unique()}",
          "email" => "globex-#{unique()}@example.test"
        })

      assert {:ok, company} = Companies.create_from_user(user)
      assert company.name == user.organization_name
      assert company.email == user.email
      assert company.user_uuid == user.uuid
    end

    test "rejects a person user" do
      user = person_user_fixture()
      assert {:error, :not_an_organization} = Companies.create_from_user(user)
    end

    test "rejects when the user already has a mirror company — no second company is created" do
      company = company_fixture(%{"name" => "Acme"})
      user = org_user_fixture(%{"organization_name" => "Acme #{unique()}"})
      {:ok, linked} = Companies.connect_user(company, user.uuid)

      assert {:error, {:already_linked, existing}} = Companies.create_from_user(user)
      assert existing.uuid == linked.uuid

      # Still exactly the one company for this user — no orphan sibling.
      assert Companies.get_by_user_uuid(user.uuid).uuid == company.uuid
    end

    test "a create_company failure inside the transaction leaves no orphan company row" do
      # An in-memory User with a blank organization_name can't be produced
      # by Auth.register_user (registration requires it for account_type:
      # "organization"), but create_from_user only reads the struct's
      # fields — this exercises create_company's OWN validation failure
      # (Company.changeset requires :name), so nothing is ever inserted in
      # the first place. Covers that leg; see the next test for the leg
      # where create_company SUCCEEDS and connect_user is what fails —
      # that's the one an unwrapped version would actually leak.
      ghost_email = "ghost-cfu-#{unique()}@example.test"

      ghost_user = %User{
        uuid: Ecto.UUID.generate(),
        account_type: "organization",
        organization_name: nil,
        email: ghost_email
      }

      assert {:error, %Ecto.Changeset{}} = Companies.create_from_user(ghost_user)
      assert Companies.list_companies(search: ghost_email) == []
    end

    test "a connect_user failure AFTER a successful create rolls back the created company" do
      # organization_name is real, so create_company succeeds and inserts
      # a row — connect_user is what fails (:user_not_found, since this
      # uuid has no backing user row despite being well-formed). Without
      # the repo().transaction wrap, this company would be left behind,
      # created but permanently unlinked — the exact regression reported.
      ghost_email = "ghost-cfu2-#{unique()}@example.test"

      ghost_user = %User{
        uuid: Ecto.UUID.generate(),
        account_type: "organization",
        organization_name: "Ghost Corp #{unique()}",
        email: ghost_email
      }

      assert {:error, :user_not_found} = Companies.create_from_user(ghost_user)
      assert Companies.list_companies(search: ghost_email) == []
    end
  end
end
