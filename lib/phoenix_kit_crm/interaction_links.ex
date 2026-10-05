defmodule PhoenixKitCRM.InteractionLinks do
  @moduledoc """
  Makes an interaction a record other text can point at — the
  `crm_interaction` type of core's `PhoenixKit.Mentions` / `ResourceLinks`.

  Three jobs, the same three every mentionable type has:

    * `resolve_comment_resources/1` — a title and a deep link per uuid, for
      the Activity feed, Comments and the rendered `#` chip. An interaction
      has no page of its own: the link lands on its anchor's page (the
      company's or the contact's), on the interactions tab.
    * `search_resources/2` — what the `#` typeahead offers, scoped to the
      SEARCHER: only someone who may open the CRM is offered anything.
    * `visible_resource_uuids/2` — which of these the READER may see. Same
      rule: the CRM is one permission, not a per-record model, so a reader
      with CRM access sees every live interaction and anyone else sees a
      redacted chip.

  Why this exists: a task created after a meeting carries
  `#[crm_interaction:…|Meeting · Acme kickoff]` in its description, and
  core's reverse index then answers "which tasks came out of this meeting"
  (`PhoenixKit.Mentions.list_backlinks/3`) with no join table anywhere.
  """

  use Gettext, backend: PhoenixKitCRM.Gettext
  import Ecto.Query
  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitCRM.{Paths, ProjectsLink}
  alias PhoenixKitCRM.Schemas.{Company, Contact, Interaction}

  @type_key "crm_interaction"
  @search_limit 6

  @doc "The mention type this module answers for."
  @spec type() :: String.t()
  def type, do: @type_key

  @doc """
  The label a chip or a typeahead row shows for an interaction: its subject,
  else its type and date — never empty, because a token needs a label.
  """
  @spec label(Interaction.t()) :: String.t()
  def label(%Interaction{subject: subject}) when is_binary(subject) and subject != "" do
    subject
  end

  def label(%Interaction{interaction_type: type, occurred_at: at}) do
    date = if at, do: Calendar.strftime(at, "%Y-%m-%d"), else: ""
    String.trim("#{Interaction.type_label(type)} · #{date}", " ·")
  end

  @doc "Title + raw path per uuid, for core's resolver. Trashed anchors resolve too — a link to a record that still exists."
  @spec resolve_comment_resources([binary()]) :: %{binary() => map()}
  def resolve_comment_resources(uuids) when is_list(uuids) do
    uuids
    |> load()
    |> Map.new(fn i -> {i.uuid, %{title: label(i), path: anchor_path(i)}} end)
  rescue
    e ->
      Logger.warning("[CRM.InteractionLinks] resolve failed: #{Exception.message(e)}")
      %{}
  end

  def resolve_comment_resources(_), do: %{}

  @doc """
  Interactions matching `query` by subject or anchor name, for a searcher
  who may open the CRM. Typed inside a project (`opts[:context]` carries
  `%{"project" => uuid}`), only the interactions of that project and the
  sub-projects under it — the field says what is relevant; CRM access
  still decides whether anything is offered at all.
  """
  @spec search_resources(String.t(), keyword()) :: [map()]
  def search_resources(query, opts) do
    if crm_access?(opts), do: do_search(query, Keyword.get(opts, :context)), else: []
  rescue
    e ->
      Logger.warning("[CRM.InteractionLinks] search failed: #{Exception.message(e)}")
      []
  end

  @doc "Of `uuids`, the ones this viewer may see: all of them with CRM access, none without."
  @spec visible_resource_uuids([binary()], keyword()) :: [binary()]
  def visible_resource_uuids(uuids, opts) do
    if crm_access?(opts), do: uuids, else: []
  rescue
    _ -> []
  end

  defp do_search(query, context) do
    pattern = "%#{escape_like(query)}%"

    Interaction
    |> join(:left, [i], c in Contact, on: c.uuid == i.contact_uuid)
    |> join(:left, [i, _c], co in Company, on: co.uuid == i.company_uuid)
    |> within_project(context)
    |> where(
      [i, c, co],
      ilike(i.subject, ^pattern) or ilike(c.name, ^pattern) or ilike(co.name, ^pattern)
    )
    |> where([i, c, co], is_nil(c.uuid) or c.status != "trashed")
    |> where([i, c, co], is_nil(co.uuid) or co.status != "trashed")
    |> order_by([i], desc: i.occurred_at)
    |> limit(@search_limit)
    |> RepoHelper.repo().all()
    |> RepoHelper.repo().preload([:contact, :company])
    |> Enum.map(fn i ->
      %{type: @type_key, uuid: i.uuid, title: label(i), subtitle: subtitle(i)}
    end)
  end

  defp within_project(queryable, %{"project" => uuid}) when is_binary(uuid) do
    where(queryable, [i], i.project_uuid in ^ProjectsLink.subtree_uuids(uuid))
  end

  defp within_project(queryable, _context), do: queryable

  defp subtitle(%Interaction{} = i) do
    who =
      case {i.contact, i.company} do
        {%Contact{} = c, _} -> Contact.display_name(c)
        {_, %Company{} = co} -> Company.display_name(co)
        _ -> nil
      end

    [gettext("Interaction"), who, i.occurred_at && Calendar.strftime(i.occurred_at, "%Y-%m-%d")]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" · ")
  end

  defp load([]), do: []

  defp load(uuids) do
    Interaction
    |> where([i], i.uuid in ^uuids)
    |> RepoHelper.repo().all()
  end

  # The anchor's page, interactions tab. Raw (no URL prefix): core applies
  # `Routes.path/1` once at render, like every handler's path.
  defp anchor_path(%Interaction{company_uuid: uuid}) when is_binary(uuid),
    do: Paths.company_raw(uuid) <> "?tab=interactions"

  defp anchor_path(%Interaction{contact_uuid: uuid}) when is_binary(uuid),
    do: Paths.contact_raw(uuid) <> "?tab=interactions"

  defp anchor_path(_), do: Paths.index()

  # One permission for the whole CRM: the module on, and the asker allowed
  # into it. The asker arrives as a scope (the typeahead) or a user uuid
  # (a render for someone else); nothing identifiable means nothing shown.
  defp crm_access?(opts) do
    scope =
      case Keyword.get(opts, :scope) do
        %Scope{} = scope -> scope
        _ -> scope_for(Keyword.get(opts, :user_uuid))
      end

    PhoenixKitCRM.enabled?() and Scope.has_module_access?(scope, PhoenixKitCRM.module_key())
  end

  defp scope_for(uuid) when is_binary(uuid) do
    case Auth.get_user(uuid) do
      nil -> nil
      user -> Scope.for_user(user)
    end
  rescue
    _ -> nil
  end

  defp scope_for(_), do: nil

  defp escape_like(value) do
    value
    |> Kernel.to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end
end
