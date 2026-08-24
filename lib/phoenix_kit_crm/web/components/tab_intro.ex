defmodule PhoenixKitCRM.Web.Components.TabIntro do
  @moduledoc """
  One line under a show-page tab heading saying what the tab shows and how
  something gets into it — with the way to do that as an inline link when
  it happens on another page.

  Every tab on the contact and company pages is fed from somewhere else
  (a contact's edit form, a member's interaction log, the catalogue's item
  form, the activity log), and without this line an empty tab read as
  broken rather than as "nothing here yet, and here is where to add it".
  """
  use Phoenix.Component

  @doc """
  The explanatory line. `text` is the sentence; the `:action` slots render
  after it as links (each slot takes `navigate` and its label as content).
  """
  attr(:text, :string, required: true)
  attr(:class, :string, default: nil)

  slot :action do
    attr(:navigate, :string, required: true)
  end

  def tab_intro(assigns) do
    ~H"""
    <p class={["text-sm text-base-content/60 flex flex-wrap items-center gap-x-3 gap-y-1", @class]}>
      <span>{@text}</span>
      <.link
        :for={action <- @action}
        navigate={action.navigate}
        class="link link-primary link-hover text-sm font-medium inline-flex items-center gap-1"
      >
        {render_slot(action)}
      </.link>
    </p>
    """
  end
end
