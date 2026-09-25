defmodule PhoenixKitCRM.Web.MediaAvatarTest do
  @moduledoc """
  The Images tab clears the avatar when the image it points at is removed
  — deciding from the row, not the tab's copy, which another session may
  have outdated by setting a new avatar since the tab loaded.
  """
  use PhoenixKitCRM.LiveCase

  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.{Attachments, Contacts}
  alias PhoenixKitCRM.Test.Repo

  setup %{conn: conn} do
    {:ok, owner} =
      Auth.register_user(%{
        "email" => "media-avatar-#{System.unique_integer([:positive])}@example.test",
        "password" => "Sup3rSecret!24"
      })

    {:ok, contact} = Contacts.create_contact(%{"name" => "Pictured Pat"})
    {:ok, images} = Attachments.ensure_folder(:contact, contact.uuid, :images, nil)

    {:ok,
     conn: put_test_scope(conn, fake_scope()), contact: contact, images: images, owner: owner}
  end

  defp photo!(folder_uuid, owner) do
    n = System.unique_integer([:positive])

    Repo.insert!(%StorageFile{
      original_file_name: "p#{n}.png",
      file_name: "p#{n}.png",
      mime_type: "image/png",
      file_type: "image",
      ext: "png",
      file_checksum: "c#{n}",
      user_file_checksum: "u#{n}",
      size: 1,
      status: "active",
      folder_uuid: folder_uuid,
      user_uuid: owner.uuid
    })
  end

  defp remove(view, file) do
    view
    |> element(~s(button[phx-click="remove_file"][phx-value-uuid="#{file.uuid}"]))
    |> render_click()
  end

  test "removing the avatar's image clears the avatar", ctx do
    old = photo!(ctx.images, ctx.owner)
    {:ok, _} = Attachments.set_avatar(:contact, ctx.contact, old.uuid)

    {:ok, view, _html} = live(ctx.conn, "/en/admin/crm/contacts/#{ctx.contact.uuid}?tab=images")
    remove(view, old)

    assert Attachments.avatar_uuid(Repo.reload(ctx.contact)) == nil
  end

  test "an avatar set by another session since the tab loaded survives the removal", ctx do
    [old, new] = [photo!(ctx.images, ctx.owner), photo!(ctx.images, ctx.owner)]
    {:ok, _} = Attachments.set_avatar(:contact, ctx.contact, old.uuid)

    {:ok, view, _html} = live(ctx.conn, "/en/admin/crm/contacts/#{ctx.contact.uuid}?tab=images")

    # Another session picks a new avatar; this tab still shows the old one.
    {:ok, _} = Attachments.set_avatar(:contact, ctx.contact, new.uuid)
    remove(view, old)

    assert Attachments.avatar_uuid(Repo.reload(ctx.contact)) == new.uuid
  end

  test "the page's Remove photo clears only the photo it shows", ctx do
    [old, new] = [photo!(ctx.images, ctx.owner), photo!(ctx.images, ctx.owner)]
    {:ok, _} = Attachments.set_avatar(:contact, ctx.contact, old.uuid)
    {:ok, view, _html} = live(ctx.conn, "/en/admin/crm/contacts/#{ctx.contact.uuid}")

    {:ok, _} = Attachments.set_avatar(:contact, ctx.contact, new.uuid)
    render_click(view, "remove_avatar", %{})

    assert Attachments.avatar_uuid(Repo.reload(ctx.contact)) == new.uuid
  end
end
