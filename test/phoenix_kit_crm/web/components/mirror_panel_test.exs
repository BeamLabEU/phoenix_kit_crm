defmodule PhoenixKitCRM.Web.Components.MirrorPanelTest do
  @moduledoc """
  Render tests for the mirror-status panel. Presentational component —
  no DB, no LiveView process, `render_component/2` against the function
  directly.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitCRM.Web.Components.MirrorPanel

  describe "linked state" do
    test "shows the linked user's name, email, and the unlink/view-account actions" do
      user = %User{
        uuid: "u1",
        email: "acme@example.test",
        account_type: "organization",
        organization_name: "Acme GmbH"
      }

      html =
        render_component(&MirrorPanel.mirror_panel/1,
          kind: :company,
          linked_user: user,
          can_link: true,
          account_path: "/admin/users/u1"
        )

      assert html =~ "Acme GmbH"
      assert html =~ "acme@example.test"
      assert html =~ "mirror_unlink"
      assert html =~ "View account"
      assert html =~ ~s(href="/admin/users/u1")

      # Not linked-state buttons.
      refute html =~ "mirror_create"
      refute html =~ "mirror_open_picker"
    end

    test "omits the account link when account_path is nil" do
      user = %User{uuid: "u1", email: "a@b.test", first_name: "Anna", last_name: "Kask"}

      html =
        render_component(&MirrorPanel.mirror_panel/1,
          kind: :contact,
          linked_user: user,
          can_link: true,
          account_path: nil
        )

      assert html =~ "Anna Kask"
      refute html =~ "View account"
    end

    test "badge label is Login for :contact and Mirror for :company" do
      user = %User{uuid: "u1", email: "a@b.test", first_name: "Anna", last_name: "Kask"}

      contact_html =
        render_component(&MirrorPanel.mirror_panel/1, kind: :contact, linked_user: user)

      company_html =
        render_component(&MirrorPanel.mirror_panel/1, kind: :company, linked_user: user)

      assert contact_html =~ "Login"
      assert company_html =~ "Mirror"
    end

    test "falls back to email when the user has no usable name" do
      user = %User{uuid: "u1", email: "nameless@example.test"}

      html = render_component(&MirrorPanel.mirror_panel/1, kind: :contact, linked_user: user)

      assert html =~ "nameless@example.test"
    end
  end

  describe "unlinked state" do
    test "shows both action buttons when can_link" do
      html =
        render_component(&MirrorPanel.mirror_panel/1,
          kind: :contact,
          linked_user: nil,
          can_link: true
        )

      assert html =~ "mirror_create"
      assert html =~ "mirror_open_picker"
      assert html =~ "Create mirror user"
      assert html =~ "Link existing"
      refute html =~ "mirror_unlink"
    end

    test "company + can_link=false shows the disabled hint instead of action buttons" do
      html =
        render_component(&MirrorPanel.mirror_panel/1,
          kind: :company,
          linked_user: nil,
          can_link: false
        )

      assert html =~ "Enable organization accounts"
      refute html =~ "mirror_create"
      refute html =~ "mirror_open_picker"
    end

    test "the disabled hint is company-specific — contact + can_link=false shows neither" do
      # Not a state the spec calls for (contact's can_link is always true),
      # but the component must still degrade sanely instead of showing a
      # company-worded hint on a contact panel.
      html =
        render_component(&MirrorPanel.mirror_panel/1,
          kind: :contact,
          linked_user: nil,
          can_link: false
        )

      refute html =~ "Enable organization accounts"
      refute html =~ "mirror_create"
    end
  end
end
