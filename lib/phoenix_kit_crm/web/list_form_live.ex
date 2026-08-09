defmodule PhoenixKitCRM.Web.ListFormLive do
  @moduledoc "New / edit form for a CRM contact list."
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitCRM.Gettext

  require Logger

  alias PhoenixKit.Modules.Languages
  alias PhoenixKitCRM.{Activity, Lists, Paths}
  alias PhoenixKitCRM.Schemas.ContactList

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    case socket.assigns.live_action do
      :new ->
        {:noreply, assign_form(socket, %ContactList{}, gettext("New list"))}

      :edit ->
        case Lists.get_list(params["uuid"]) do
          nil ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("List not found"))
             |> push_navigate(to: Paths.lists())}

          list ->
            {:noreply, assign_form(socket, list, gettext("Edit list"))}
        end
    end
  end

  defp assign_form(socket, list, title) do
    socket
    |> assign(:list, list)
    |> assign(:page_title, title)
    |> assign(:page_section, gettext("Lists"))
    |> assign(:page_section_path, Paths.lists())
    |> assign(:form, to_form(Lists.change_list(list), as: :list))
  end

  @impl true
  def handle_event("validate", %{"list" => params} = _payload, socket) do
    changeset =
      socket.assigns.list
      |> Lists.change_list(safe_map(params))
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset, as: :list))}
  end

  def handle_event("save", %{"list" => params}, socket) do
    save(socket, socket.assigns.live_action, safe_map(params))
  rescue
    e ->
      Logger.error(
        "[CRM] list save crashed (list_uuid=#{inspect(socket.assigns.list.uuid)}): " <>
          Exception.format(:error, e, __STACKTRACE__)
      )

      changeset =
        socket.assigns.list |> Lists.change_list(params) |> Map.put(:action, :validate)

      {:noreply,
       socket
       |> put_flash(
         :error,
         gettext("Something went wrong saving this list. Your input was kept — please try again.")
       )
       |> assign(:form, to_form(changeset, as: :list))}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp save(socket, :new, params) do
    case Lists.create_list(params, Activity.actor_opts(socket)) do
      {:ok, list} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("List created"))
         |> push_navigate(to: Paths.list_members(list.uuid))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :list))}
    end
  end

  defp save(socket, :edit, params) do
    case Lists.update_list(socket.assigns.list, params, Activity.actor_opts(socket)) do
      {:ok, list} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("List updated"))
         |> push_navigate(to: Paths.list_members(list.uuid))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :list))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="container flex-col mx-auto px-4 py-6 max-w-2xl">
      <.form for={@form} id="crm-list-form" phx-change="validate" phx-submit="save">
        <div class="card bg-base-100 shadow-sm">
          <div class="card-body flex flex-col gap-5">
            <.input field={@form[:name]} label={gettext("Name")} required />
            <.input
              field={@form[:slug]}
              label={gettext("Slug")}
              placeholder={gettext("auto-generated from the name if left blank")}
            />
            <.textarea field={@form[:description]} label={gettext("Description")} />

            <.checkbox field={@form[:subscribable]} label={gettext("Subscribable")}>
              <:description>
                {gettext("Shown to contacts in the preference center (once available).")}
              </:description>
            </.checkbox>

            <div>
              <.select
                field={@form[:locale]}
                label={gettext("Locale")}
                options={locale_options()}
                prompt={gettext("Not set")}
              />
              <p class="text-xs text-base-content/50 mt-1">
                {gettext(
                  "Content language for this list's contacts. Can be bulk-applied to members from the list's page."
                )}
              </p>
            </div>

            <div :if={@list.uuid} class="divider my-1 text-sm font-semibold text-base-content/60">
              {gettext("Status")}
            </div>
            <.select
              :if={@list.uuid}
              field={@form[:status]}
              label={gettext("Status")}
              options={status_options()}
            />

            <div class="divider my-0"></div>
            <div class="flex justify-end gap-2">
              <.link navigate={Paths.lists()} class="btn btn-ghost">{gettext("Cancel")}</.link>
              <.button type="submit" class="btn-primary" phx-disable-with={gettext("Saving…")}>
                {gettext("Save")}
              </.button>
            </div>
          </div>
        </div>
      </.form>
    </div>
    """
  end

  defp status_options, do: Enum.map(ContactList.statuses(), &{status_label(&1), &1})

  defp status_label("active"), do: gettext("Active")
  defp status_label("archived"), do: gettext("Archived")
  defp status_label(s), do: s

  # Sourced from the site's configured content languages (falls back to a
  # curated default set when the Languages module isn't configured) rather
  # than a free-text field like `Contact.locale` — a list's locale drives a
  # bulk-apply action, so it's worth constraining it to languages the site
  # can actually address.
  defp locale_options, do: Enum.map(Languages.get_display_languages(), &{&1.name, &1.code})

  defp safe_map(p) when is_map(p), do: p
  defp safe_map(_), do: %{}
end
