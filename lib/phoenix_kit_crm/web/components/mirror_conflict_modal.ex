defmodule PhoenixKitCRM.Web.Components.MirrorConflictModal do
  @moduledoc """
  The per-field "ask, don't silently overwrite" divergence-resolution
  modal (owner Q5) — one row per `PhoenixKitCRM.Mirror.diff/2` entry, a
  radio choosing which side wins that field, defaulting to `@master`'s
  side.

  Pure presentation function component. The consumer LiveView owns
  `@conflicts` (from `Mirror.diff/2`) and `@master`, and implements:

      mirror_resolve         — form submit; receives
                                %{"choices" => %{"<field>" => "keep_crm" | "keep_user"}}
                                for every conflict — feed straight into
                                Mirror.resolve/4 after converting the
                                string field keys back to atoms and the
                                "keep_crm"/"keep_user" values to :crm/:user.
      mirror_cancel_conflict — Cancel clicked / modal dismissed

  Renders nothing when `@conflicts` is empty — there is nothing to ask.

  ## Usage

      <.mirror_conflict_modal show={@show_conflict} conflicts={@conflicts} master={@master} />
  """

  use PhoenixKitWeb, :html
  use Gettext, backend: PhoenixKitCRM.Gettext

  attr(:conflicts, :list, default: [])
  attr(:master, :atom, required: true, values: [:crm, :user])
  attr(:show, :boolean, default: false)

  def mirror_conflict_modal(assigns) do
    ~H"""
    <.modal
      :if={@conflicts != []}
      show={@show}
      on_close="mirror_cancel_conflict"
      max_width="lg"
      id="mirror-conflict-modal"
    >
      <:title>{gettext("Resolve differences")}</:title>

      <.form
        for={%{}}
        id="mirror-conflict-form"
        phx-submit="mirror_resolve"
        class="space-y-4"
      >
        <p class="text-sm text-base-content/70">
          {gettext("These fields differ. Choose which side to keep for each.")}
        </p>

        <div :for={conflict <- @conflicts} class="space-y-1" data-testid={"conflict-row-#{conflict.field}"}>
          <div class="text-sm font-medium">{conflict.label}</div>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
            <label class="label cursor-pointer justify-start gap-2 rounded border border-base-300 p-2">
              <input
                type="radio"
                name={"choices[#{conflict.field}]"}
                value="keep_crm"
                checked={@master == :crm}
                class="radio radio-sm"
              />
              <span class="label-text text-sm">{conflict.crm}</span>
            </label>
            <label class="label cursor-pointer justify-start gap-2 rounded border border-base-300 p-2">
              <input
                type="radio"
                name={"choices[#{conflict.field}]"}
                value="keep_user"
                checked={@master == :user}
                class="radio radio-sm"
              />
              <span class="label-text text-sm">{conflict.user}</span>
            </label>
          </div>
        </div>

        <div class="modal-action">
          <.button type="button" variant="ghost" phx-click="mirror_cancel_conflict">
            {gettext("Cancel")}
          </.button>
          <.button type="submit" variant="primary">
            {gettext("Apply")}
          </.button>
        </div>
      </.form>
    </.modal>
    """
  end
end
