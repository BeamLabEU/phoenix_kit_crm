defmodule PhoenixKitCRM.MediaReorganizer do
  @moduledoc """
  CRM's media-reorganizer plan source: the `crm-contact-<uuid>`,
  `crm-company-<uuid>` and `crm-interaction-<uuid>` folders, planned by core's
  `PhoenixKit.Modules.Storage.Reorganizer.ResourceSource`, which applies the
  `Reorganizer.Source` contract.

  What is CRM's own: contacts and companies are live until trashed; an
  interaction is live while its anchor contact or company is — the folder of
  one whose anchor is trashed is reported as an orphan wherever it sits (the
  one report CRM adds itself). The parent hook receives the record's uuid as
  its subject. No record stores a folder pointer (folders are found by
  name), so a taken target is reported rather than renamed, and CRM stages
  no uploads before a record exists.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Storage.{Folder, FolderLink}
  alias PhoenixKit.Modules.Storage.Reorganizer.ResourceSource
  alias PhoenixKitCRM.Attachments
  alias PhoenixKitCRM.Schemas.{Company, Contact, Interaction}

  @doc "The plan (`Reorganizer.Source.plan/2`); `opts` is passed through."
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, opts \\ []), do: ResourceSource.plan(spec(), actor_uuid, opts)

  defp spec do
    %{
      source: "crm",
      app: :phoenix_kit_crm,
      kinds: [
        %{
          kind: :contact,
          schema: Contact,
          prefix: "crm-contact-",
          subject: :uuid,
          live: &untrashed/1
        },
        %{
          kind: :company,
          schema: Company,
          prefix: "crm-company-",
          subject: :uuid,
          live: &untrashed/1
        },
        %{
          kind: :interaction,
          schema: Interaction,
          prefix: "crm-interaction-",
          subject: :uuid,
          label: :subject,
          fields: [:contact_uuid, :company_uuid],
          live: &anchor_live/1,
          # A trashed anchor's interaction folders are reported by
          # `trashed_anchor_orphans/2`, wherever they sit.
          orphan: :missing
        }
      ],
      extra: &trashed_anchor_orphans/2
    }
  end

  defp untrashed(query), do: where(query, [r], r.status != "trashed")

  defp anchor_live(query) do
    query
    |> join(:left, [i], c in Contact, as: :anchor_contact, on: i.contact_uuid == c.uuid)
    |> join(:left, [i], co in Company, as: :anchor_company, on: i.company_uuid == co.uuid)
    |> where(
      [anchor_contact: c, anchor_company: co],
      (is_nil(c.uuid) or c.status != "trashed") and (is_nil(co.uuid) or co.status != "trashed")
    )
  end

  # Every live folder of an interaction whose anchor contact or company is
  # trashed, found by name anywhere: the record exists, so the scoped
  # orphan scan leaves it, but nothing will move or open it again.
  defp trashed_anchor_orphans(_actor_uuid, _opts) do
    anchored =
      trashed_anchor(Contact, :contact_uuid, "contact") ++
        trashed_anchor(Company, :company_uuid, "company")

    names =
      Map.new(anchored, fn {i, anchor} ->
        {Attachments.interaction_folder_name(i.uuid), {i, anchor}}
      end)

    case Map.keys(names) do
      [] ->
        []

      keys ->
        folders =
          from(f in Folder,
            where: f.name in ^keys and is_nil(f.trashed_at),
            order_by: [asc: f.inserted_at, asc: f.uuid]
          )
          |> repo().all()

        counts = counts(Enum.map(folders, & &1.uuid))

        Enum.map(folders, fn folder ->
          {interaction, anchor} = Map.fetch!(names, folder.name)

          %{
            source: "crm",
            kind: :orphan,
            op: :report,
            label: label(interaction),
            folder: folder,
            counts: Map.get(counts, folder.uuid, {0, 0}),
            reason: "interaction's anchor #{anchor} is trashed"
          }
        end)
    end
  end

  defp trashed_anchor(schema, anchor_field, anchor) do
    from(i in Interaction,
      join: a in ^schema,
      on: field(i, ^anchor_field) == a.uuid and a.status == "trashed",
      order_by: [asc: i.inserted_at, asc: i.uuid],
      select: struct(i, [:uuid, :subject])
    )
    |> repo().all()
    |> Enum.map(&{&1, anchor})
  end

  defp label(%Interaction{subject: subject, uuid: uuid}) when subject in [nil, ""], do: uuid
  defp label(%Interaction{subject: subject}), do: subject

  # Every file row homed in each folder (any status) and every link into it.
  defp counts([]), do: %{}

  defp counts(uuids) do
    files =
      from(f in PhoenixKit.Modules.Storage.File,
        where: f.folder_uuid in ^uuids,
        group_by: f.folder_uuid,
        select: {f.folder_uuid, count(f.uuid)}
      )
      |> repo().all()
      |> Map.new()

    links =
      from(l in FolderLink,
        where: l.folder_uuid in ^uuids,
        group_by: l.folder_uuid,
        select: {l.folder_uuid, count(l.uuid)}
      )
      |> repo().all()
      |> Map.new()

    Map.new(uuids, &{&1, {Map.get(files, &1, 0), Map.get(links, &1, 0)}})
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
