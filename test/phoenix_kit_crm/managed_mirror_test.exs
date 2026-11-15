defmodule PhoenixKitCRM.ManagedMirrorTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitCRM.{ManagedMirror, Mirror}
  alias PhoenixKitCRM.Schemas.Company

  defp managed(attrs \\ %{}) do
    struct(
      User,
      Map.merge(
        %{
          account_type: "organization",
          managed_by_members: true,
          email: "org-placeholder@organization.invalid",
          contact_email: "shared@example.com",
          organization_name: "Acme"
        },
        attrs
      )
    )
  end

  test "creation maps shared email to contact, never login" do
    attrs =
      Mirror.attrs_from(:company, %Company{name: "Acme", email: " shared@example.com "},
        managed: true
      )

    assert attrs == %{
             account_type: "organization",
             organization_name: "Acme",
             contact_email: "shared@example.com"
           }

    refute Map.has_key?(attrs, :email)
  end

  test "matching contact has no placeholder-email conflict" do
    assert Mirror.diff(%Company{name: "Acme", email: "shared@example.com"}, managed()) == []
  end

  test "both resolution directions use contact_email and leave login untouched" do
    company = %Company{name: "Acme", email: "crm@example.com"}
    user = managed()

    assert [%{field: :email, user: "shared@example.com", crm: "crm@example.com"}] =
             Mirror.diff(company, user)

    assert Mirror.resolve(:company, company, user, %{email: :crm}) == %{
             crm: %{},
             user: %{contact_email: "crm@example.com"}
           }

    assert Mirror.resolve(:company, company, user, %{email: :user}) == %{
             crm: %{email: "shared@example.com"},
             user: %{}
           }

    assert Mirror.attrs_to_crm(:company, user) == %{name: "Acme", email: "shared@example.com"}
  end

  test "absent contact stays absent; placeholder is never a fallback" do
    user = managed(%{contact_email: nil})
    assert Mirror.user_email(user) == nil
    assert Mirror.attrs_to_crm(:company, user).email == nil
    assert Mirror.diff(%Company{name: "Acme", email: "contact@example.com"}, user) == []
  end

  test "a managed account is never an unclaimed CRM placeholder" do
    refute Mirror.placeholder_user?(
             managed(%{confirmed_at: nil, custom_fields: %{"source" => "crm_company"}})
           )
  end
end
