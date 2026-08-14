defmodule PhoenixKitCRM.Web.Components.MirrorConflictModal do
  @moduledoc """
  The per-field "ask, don't silently overwrite" divergence-resolution
  modal (owner Q5) — one row per `PhoenixKitCRM.Mirror.diff/2` entry, a
  radio choosing which side wins that field.

  Pure presentation function component. The consumer LiveView owns
  `@conflicts` (from `Mirror.diff/2`), `@master`, and `@choices` (the
  in-progress selection — see below), and implements:

      mirror_choice_changed  — form phx-change; receives
                                %{"choices" => %{"<field>" => "keep_crm" | "keep_user"}}
                                for whichever radios are currently
                                rendered — merge into the server-tracked
                                `@choices` (whitelisted against the
                                current `@conflicts` field set; never
                                `String.to_atom/1` a submitted key).
      mirror_resolve         — form submit; same payload shape as above.
                                Re-fetch the CRM record and the User
                                fresh (records may have changed while the
                                modal was open) and call `Mirror.diff/2`
                                again before `Mirror.resolve/4` — the
                                whole reason `resolve/4` re-checks
                                divergence internally is so a field that
                                stopped diverging while the modal was
                                open is dropped, not blindly applied.
      mirror_cancel_conflict — Cancel clicked / modal dismissed

  Renders nothing when `@conflicts` is empty — there is nothing to ask.

  ## Why `@choices` exists — controlled, not derived from `@master` alone

  Earlier this modal derived every radio's `checked` from `@master` alone
  (`checked={@master == :crm}`) with no way for a consumer to represent an
  in-progress selection. That made the radios UNCONTROLLED: the user's
  click lived only in the DOM, so ANY parent re-render while the modal
  was open (a flash, a PubSub event, a `phx-change` on the underlying
  form) made LiveView's DOM patch re-apply the server-rendered `checked`
  and silently revert the selection back to `@master` — Apply could then
  resolve with choices the user never made. `@choices` (`%{field_atom =>
  :crm | :user}`, default `%{}`) makes the modal a normal controlled
  LiveView form: a field with no entry in `@choices` still defaults to
  `@master` (so a consumer that never wires `mirror_choice_changed` sees
  identical behavior to before), but once a choice is recorded server-
  side it survives any re-render.

  ## Usage

      <.mirror_conflict_modal
        show={@show_conflict}
        conflicts={@mirror_conflicts}
        master={:crm}
        choices={@mirror_choices}
      />
  """

  use PhoenixKitWeb, :html
  use Gettext, backend: PhoenixKitCRM.Gettext

  attr(:conflicts, :list, default: [])
  attr(:master, :atom, required: true, values: [:crm, :user])
  attr(:show, :boolean, default: false)
  attr(:choices, :map, default: %{})

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
        phx-change="mirror_choice_changed"
        phx-submit="mirror_resolve"
        class="space-y-4"
      >
        <p class="text-sm text-base-content/70">
          {gettext("These fields differ. Choose which side to keep for each.")}
        </p>

        <div
          :for={conflict <- @conflicts}
          class="space-y-1"
          data-testid={"conflict-row-#{conflict.field}"}
        >
          <div class="text-sm font-medium">{conflict.label}</div>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-2">
            <label class="label cursor-pointer justify-start gap-2 rounded border border-base-300 p-2">
              <input
                type="radio"
                name={"choices[#{conflict.field}]"}
                value="keep_crm"
                checked={Map.get(@choices, conflict.field, @master) == :crm}
                class="radio radio-sm"
              />
              <span class="label-text text-sm">{conflict.crm}</span>
            </label>
            <label class="label cursor-pointer justify-start gap-2 rounded border border-base-300 p-2">
              <input
                type="radio"
                name={"choices[#{conflict.field}]"}
                value="keep_user"
                checked={Map.get(@choices, conflict.field, @master) == :user}
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
