defmodule PhoenixKitCRM.Web.InteractionAttachmentsTest do
  @moduledoc """
  The composer's attachment dropzone, with Storage genuinely enabled.

  This coverage exists because the dropzone was silently gone module-wide for
  weeks: `allow_upload` raises on any accept extension the mime library can't
  name (.m4a/.ogg/.mkv under mime 2.0.7), and a silent rescue downgraded the
  raise to `can_attach: false` with no trace. Every other test ran with
  Storage off, so nothing ever rendered the dropzone at all.
  """
  use PhoenixKitCRM.LiveCase

  import Ecto.Query
  import ExUnit.CaptureLog

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Users.Auth
  alias PhoenixKitCRM.{Attachments, Companies, Contacts, Interactions}
  alias PhoenixKitCRM.Test.Repo
  alias PhoenixKitCRM.Web.InteractionsComponent

  setup %{conn: conn} do
    :persistent_term.erase(:phoenix_kit_buckets_cache)

    # Stored files go to every enabled bucket; keep them all in this one.
    for bucket <- Storage.list_enabled_buckets(),
        do: {:ok, _} = Storage.update_bucket(bucket, %{enabled: false})

    root = Path.join(System.tmp_dir!(), "crm_attach_#{System.unique_integer([:positive])}")

    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "Attach Bucket #{System.unique_integer([:positive])}",
        provider: "local",
        endpoint: root
      })

    on_exit(fn ->
      :persistent_term.erase(:phoenix_kit_buckets_cache)
      File.rm_rf(root)
    end)

    {:ok, conn: put_test_scope(conn, fake_scope()), bucket: bucket}
  end

  test "the contact composer offers the dropzone when storage has a bucket", %{conn: conn} do
    {:ok, contact} = Contacts.create_contact(%{"name" => "Attach Anna"})

    {:ok, _view, html} = live(conn, "/en/admin/crm/contacts/#{contact.uuid}?tab=interactions")

    assert html =~ "Drag files here or click to upload"
  end

  test "the composer's form carries the id LiveView recovers it by", %{conn: conn} do
    {:ok, contact} = Contacts.create_contact(%{"name" => "Recover Rita"})
    {:ok, view, _html} = live(conn, "/en/admin/crm/contacts/#{contact.uuid}?tab=interactions")
    assert has_element?(view, "form[id$='-composer'][phx-change]")
  end

  test "the company composer offers the dropzone too", %{conn: conn} do
    {:ok, company} = Companies.create_company(%{"name" => "Attach Co"})

    {:ok, _view, html} =
      live(conn, "/en/admin/crm/companies/#{company.uuid}?tab=interactions")

    assert html =~ "Drag files here or click to upload"
  end

  test "no enabled bucket, no dropzone — storage on alone is not enough", %{conn: conn} do
    # The setup-created bucket exists in THIS test too (sandboxed per test?
    # no — setup runs per test, so disable it) — verify by disabling every
    # bucket first.
    for bucket <- Storage.list_enabled_buckets() do
      {:ok, _} = Storage.update_bucket(bucket, %{enabled: false})
    end

    {:ok, contact} = Contacts.create_contact(%{"name" => "Bucketless Bella"})

    {:ok, _view, html} = live(conn, "/en/admin/crm/contacts/#{contact.uuid}?tab=interactions")

    refute html =~ "Drag files here or click to upload"
  end

  test "every offered accept extension is one the mime library can name" do
    # Mirrors `allow_upload`'s own gate: one unknown extension in the accept
    # list raises and takes the whole dropzone with it.
    for "." <> ext <- InteractionsComponent.__known_upload_accept__() do
      assert MIME.has_type?(ext), "accept list offers .#{ext}, which mime cannot name"
    end
  end

  test "an upload is staged under its base name, typed by core", %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "attach-upload-#{System.unique_integer([:positive])}@example.test",
        "password" => "Sup3rSecret!24"
      })

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid))
    {:ok, contact} = Contacts.create_contact(%{"name" => "Upload Uma"})
    {:ok, view, _html} = live(conn, "/en/admin/crm/contacts/#{contact.uuid}?tab=interactions")

    file =
      file_input(view, "form[id^='crm-attach-']", :attachments, [
        %{
          last_modified: 1_700_000_000_000,
          name: "../../plan.pdf",
          content: "plan #{contact.uuid}",
          type: "application/pdf"
        }
      ])

    # Variant jobs cannot be queued without Oban; that is logged, not raised.
    capture_log(fn -> render_upload(file, "../../plan.pdf") end)

    assert [stored] = Repo.all(from(f in StorageFile, where: f.user_uuid == ^user.uuid))
    assert stored.original_file_name == "plan.pdf"
    assert stored.file_type == "document"
    assert stored.folder_uuid == nil
    assert render(view) =~ "plan.pdf"
  end

  test "an upload that cannot be stored says so instead of freezing", %{
    conn: conn,
    bucket: bucket
  } do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "attach-fail-#{System.unique_integer([:positive])}@example.test",
        "password" => "Sup3rSecret!24"
      })

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid))
    {:ok, contact} = Contacts.create_contact(%{"name" => "Failing Fay"})
    {:ok, view, _html} = live(conn, "/en/admin/crm/contacts/#{contact.uuid}?tab=interactions")

    # The bucket goes away between showing the dropzone and the upload.
    {:ok, bucket} = Storage.update_bucket(bucket, %{enabled: false})
    :persistent_term.erase(:phoenix_kit_buckets_cache)

    file =
      file_input(view, "form[id^='crm-attach-']", :attachments, [
        %{
          last_modified: 1_700_000_000_000,
          name: "lost.pdf",
          content: "lost",
          type: "application/pdf"
        }
      ])

    capture_log(fn -> render_upload(file, "lost.pdf") end)

    html = render(view)
    assert html =~ "Upload failed for lost.pdf."
    refute html =~ ~s(<progress)

    # Typing does not hide it: nothing is staged, and the save would go
    # ahead without the file.
    view
    |> element("form[phx-change=composer_change]")
    |> render_change(%{"interaction" => %{"subject" => "Follow-up"}})

    assert render(view) =~ "Upload failed for lost.pdf."

    # A later upload that is stored clears it.
    {:ok, _} = Storage.update_bucket(bucket, %{enabled: true})
    :persistent_term.erase(:phoenix_kit_buckets_cache)

    upload(view, "found.pdf", "found #{contact.uuid}")
    refute render(view) =~ "Upload failed for lost.pdf."
  end

  test "re-uploading a trashed file attaches it on save", %{conn: conn} do
    {:ok, user} =
      Auth.register_user(%{
        "email" => "attach-back-#{System.unique_integer([:positive])}@example.test",
        "password" => "Sup3rSecret!24"
      })

    conn = put_test_scope(conn, fake_scope(user_uuid: user.uuid))
    {:ok, contact} = Contacts.create_contact(%{"name" => "Returning Rae"})
    {:ok, view, _html} = live(conn, "/en/admin/crm/contacts/#{contact.uuid}?tab=interactions")
    bytes = "wanted again #{contact.uuid}"

    upload(view, "notes.pdf", bytes)
    assert [stored] = Repo.all(from(f in StorageFile, where: f.user_uuid == ^user.uuid))

    # Taken back out of the composer and trashed from the media browser...
    view
    |> element(~s(button[phx-click="remove_staged_file"][phx-value-uuid="#{stored.uuid}"]))
    |> render_click()

    {:ok, _} = Storage.trash_file(stored)

    # ...then uploaded again: storage hands back the trashed row.
    upload(view, "notes.pdf", bytes)

    view
    |> element("form[phx-change=composer_change]")
    |> render_change(%{"interaction" => %{"subject" => "Brought it back"}})

    view |> element("button[phx-click=save_interaction]") |> render_click()

    assert [interaction] = Interactions.list_for_contacts([contact.uuid])

    files =
      Map.get(Attachments.list_files_by_interaction([interaction.uuid]), interaction.uuid, [])

    assert Enum.map(files, & &1.uuid) == [stored.uuid]
    assert Storage.get_file(stored.uuid).status == "active"
  end

  # Variant jobs cannot be queued without Oban; that is logged, not raised.
  defp upload(view, name, content) do
    file =
      file_input(view, "form[id^='crm-attach-']", :attachments, [
        %{last_modified: 1_700_000_000_000, name: name, content: content, type: "application/pdf"}
      ])

    capture_log(fn -> render_upload(file, name) end)
  end
end
