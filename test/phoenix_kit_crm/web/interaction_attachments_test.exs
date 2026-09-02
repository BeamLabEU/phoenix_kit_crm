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

  alias PhoenixKit.Modules.Storage
  alias PhoenixKitCRM.{Companies, Contacts}
  alias PhoenixKitCRM.Web.InteractionsComponent

  setup %{conn: conn} do
    {:ok, _} =
      Storage.create_bucket(%{
        name: "Attach Bucket #{System.unique_integer([:positive])}",
        provider: "local"
      })

    {:ok, conn: put_test_scope(conn, fake_scope())}
  end

  test "the contact composer offers the dropzone when storage has a bucket", %{conn: conn} do
    {:ok, contact} = Contacts.create_contact(%{"name" => "Attach Anna"})

    {:ok, _view, html} = live(conn, "/en/admin/crm/contacts/#{contact.uuid}?tab=interactions")

    assert html =~ "Drag files here or click to upload"
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
end
