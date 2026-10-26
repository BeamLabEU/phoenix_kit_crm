defmodule PhoenixKitCRM.Web.PartyRoleFormLive do
  @moduledoc """
  Add / edit form for a party role (Settings → CRM → Party roles): the
  translated name and description, the badge colour and the icon. The key is
  derived from the primary-language name on create — unless the admin types
  one, which a name with no Latin letters needs — and is read-only afterwards;
  a built-in role keeps its key and can be relabelled.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitCRM.Gettext

  require Logger

  import PhoenixKitWeb.Components.Core.FormActions, only: [form_actions: 1]
  import PhoenixKitWeb.Components.MultilangForm

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitCRM.{Activity, PartyRoleTypes, Paths}
  alias PhoenixKitCRM.Schemas.PartyRoleType

  @translatable_fields ["name", "description"]

  @impl true
  def mount(_params, _session, socket) do
    if PhoenixKitCRM.can_change_settings?(socket.assigns[:phoenix_kit_current_scope]) do
      {:ok, mount_multilang(socket, open_on: :primary)}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("You do not have permission to change the CRM settings."))
       |> push_navigate(to: Paths.index(), replace: true)}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case load_type(socket.assigns.live_action, params) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Party role not found"))
         |> push_navigate(to: Paths.party_roles())}

      type ->
        {:noreply,
         socket
         |> assign(
           page_title: page_title(socket.assigns.live_action),
           page_section: gettext("Settings"),
           page_section_path: Routes.path("/admin/settings"),
           page_crumbs: [
             %{label: gettext("CRM"), path: Paths.settings()},
             %{label: gettext("Party roles"), path: Paths.party_roles()}
           ],
           type: type,
           derived_key: nil
         )
         |> assign_changeset(PartyRoleTypes.change_type(type))}
    end
  end

  defp load_type(:new, _params), do: %PartyRoleType{}
  defp load_type(:edit, %{"uuid" => uuid}), do: PartyRoleTypes.get_type(uuid)

  defp page_title(:new), do: gettext("New party role")
  defp page_title(:edit), do: gettext("Edit party role")

  defp assign_changeset(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, changeset: changeset, form: to_form(changeset, as: :party_role))
  end

  @impl true
  def handle_event("switch_language", %{"lang" => lang_code}, socket) do
    {:noreply, handle_switch_language(socket, lang_code)}
  end

  def handle_event("validate", %{"party_role" => params}, socket) do
    {params, derived} = prepare(params, socket)

    changeset =
      socket.assigns.type
      |> PartyRoleTypes.change_type(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:derived_key, derived && Ecto.Changeset.get_field(changeset, :key))
     |> assign_changeset(changeset)}
  end

  def handle_event("save", %{"party_role" => params}, socket) do
    # Re-checked here, not only at mount: the vocabulary is a setting.
    if PhoenixKitCRM.can_change_settings?(socket.assigns[:phoenix_kit_current_scope]) do
      {params, _derived} = prepare(params, socket)
      save(socket, socket.assigns.live_action, params)
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         gettext("You do not have permission to change the CRM settings.")
       )}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Folds the language tabs' fields into `data`, and — on create — treats a key
  # the form is merely echoing back (blank, or the one derived last time) as
  # "not given", so the next name edit derives a fresh one instead of being
  # pinned to the first.
  defp prepare(params, socket) do
    params =
      merge_translatable_params(params, socket, @translatable_fields,
        changeset: socket.assigns.changeset
      )

    if socket.assigns.live_action == :new do
      if params["key"] in [nil, "", socket.assigns.derived_key] do
        {Map.delete(params, "key"), true}
      else
        {params, false}
      end
    else
      {Map.delete(params, "key"), false}
    end
  end

  defp save(socket, :new, params) do
    case PartyRoleTypes.create_type(params, Activity.actor_opts(socket)) do
      {:ok, _type} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Party role created"))
         |> push_navigate(to: Paths.party_roles())}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_changeset(socket, Map.put(changeset, :action, :validate))}
    end
  end

  defp save(socket, :edit, params) do
    case PartyRoleTypes.update_type(socket.assigns.type, params, Activity.actor_opts(socket)) do
      {:ok, _type} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Party role updated"))
         |> push_navigate(to: Paths.party_roles())}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_changeset(socket, Map.put(changeset, :action, :validate))}
    end
  end

  @impl true
  def handle_info(msg, socket) do
    Logger.debug("[PartyRoleFormLive] ignoring unrelated message: #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(
        :lang_data,
        get_lang_data(assigns.changeset, assigns.current_lang, assigns.multilang_enabled)
      )
      |> assign(:badges, PartyRoleType.badges())
      |> assign(:icons, PartyRoleType.icons())
      |> assign(:new?, assigns.live_action == :new)

    ~H"""
    <div class="flex flex-col w-full px-4 py-8 gap-6">
      <div class="max-w-3xl mx-auto w-full">
        <.form for={@form} id="party-role-form" phx-change="validate" phx-submit="save">
          <div class="card bg-base-100 shadow-lg">
            <.multilang_tabs
              multilang_enabled={@multilang_enabled}
              language_tabs={@language_tabs}
              current_lang={@current_lang}
              class="card-body pb-0 pt-4"
            />

            <.multilang_fields_wrapper
              multilang_enabled={@multilang_enabled}
              current_lang={@current_lang}
              skeleton_class="card-body pt-0"
            >
              <div class="card-body pt-0 flex flex-col gap-5">
                <.translatable_field
                  field_name="name"
                  form_prefix="party_role"
                  changeset={@changeset}
                  schema_field={:name}
                  multilang_enabled={@multilang_enabled}
                  current_lang={@current_lang}
                  primary_language={@primary_language}
                  lang_data={@lang_data}
                  label={gettext("Name")}
                  placeholder={name_placeholder(@type)}
                  required={not @type.builtin}
                  class="w-full"
                />

                <.translatable_field
                  field_name="description"
                  form_prefix="party_role"
                  changeset={@changeset}
                  schema_field={:description}
                  multilang_enabled={@multilang_enabled}
                  current_lang={@current_lang}
                  primary_language={@primary_language}
                  lang_data={@lang_data}
                  label={gettext("Description")}
                  type="textarea"
                  placeholder={gettext("What this role means for a company or person")}
                  class="w-full"
                />
              </div>
            </.multilang_fields_wrapper>

            <div class="card-body flex flex-col gap-5 pt-0">
              <div>
                <.input
                  field={@form[:key]}
                  label={gettext("Key")}
                  readonly={not @new?}
                  disabled={not @new?}
                  maxlength={PartyRoleType.key_max()}
                  class="font-mono"
                />
                <span class="fieldset-label text-base-content/50 mt-1">
                  <%= if @new? do %>
                    {gettext(
                      "The stable code stored on each company and person and used by other modules. Made from the name; it cannot be changed later."
                    )}
                  <% else %>
                    {gettext("The key cannot be changed.")}
                  <% end %>
                </span>
              </div>

              <fieldset class="fieldset">
                <legend class="fieldset-legend">{gettext("Badge")}</legend>
                <div class="flex flex-wrap gap-3">
                  <label :for={badge <- @badges} class="flex items-center gap-1 cursor-pointer">
                    <input
                      type="radio"
                      name="party_role[badge]"
                      value={badge}
                      checked={@form[:badge].value == badge}
                      class="radio radio-sm"
                    />
                    <span class={["badge", badge]}>{preview_name(@changeset)}</span>
                  </label>
                </div>
              </fieldset>

              <fieldset class="fieldset">
                <legend class="fieldset-legend">{gettext("Icon")}</legend>
                <div class="flex flex-wrap gap-3">
                  <label :for={icon <- @icons} class="flex items-center gap-1 cursor-pointer">
                    <input
                      type="radio"
                      name="party_role[icon]"
                      value={icon}
                      checked={@form[:icon].value == icon}
                      class="radio radio-sm"
                    />
                    <.icon name={icon} class="w-5 h-5" />
                  </label>
                </div>
              </fieldset>
            </div>
          </div>

          <.form_actions
            class="mt-6"
            cancel_to={Paths.party_roles()}
            submit_label={if @new?, do: gettext("Create role"), else: gettext("Save changes")}
            submitting_label={if @new?, do: gettext("Creating..."), else: gettext("Saving...")}
          />
        </.form>
      </div>
    </div>
    """
  end

  # A built-in is seeded without a name of its own: its label is the translated
  # default, so the field shows that as a placeholder and stays optional --
  # typing one overrides the default in every language that has no translation.
  defp name_placeholder(%PartyRoleType{builtin: true} = type), do: PartyRoleTypes.name(type)
  defp name_placeholder(_type), do: gettext("e.g., Carrier, Forwarder, Installer")

  # What the badge samples read: the name being typed, else a placeholder.
  defp preview_name(changeset) do
    case Ecto.Changeset.get_field(changeset, :name) do
      name when is_binary(name) and name != "" -> name
      _ -> gettext("Role")
    end
  end
end
