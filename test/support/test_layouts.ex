defmodule PhoenixKitCRM.Test.Layouts do
  @moduledoc """
  Minimal layouts for the LiveView test endpoint. Real layouts live in the host
  app and phoenix_kit core — these just wrap LiveView content in an HTML shell so
  Phoenix.LiveViewTest can render it. `app/1` renders flash divs so smoke tests
  can assert flash content via `render(view) =~ "Saved."` after click events.
  """

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Test</title>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  def app(assigns) do
    ~H"""
    <div id="test-flashes">
      <div :if={msg = Phoenix.Flash.get(@flash, :info)} id="flash-info" data-flash-kind="info">
        {msg}
      </div>
      <div :if={msg = Phoenix.Flash.get(@flash, :error)} id="flash-error" data-flash-kind="error">
        {msg}
      </div>
      <div
        :if={msg = Phoenix.Flash.get(@flash, :warning)}
        id="flash-warning"
        data-flash-kind="warning"
      >
        {msg}
      </div>
    </div>
    <%!-- Stand-in for the real host app's chrome breadcrumb
         (LayoutWrapper.app_layout renders page_title/page_subtitle/
         page_section in the navbar, page_section as a clickable link to
         page_section_path — see layout_wrapper.ex:378-403) — LiveViews
         assign these instead of an in-body <h1>/back-link per the
         no-duplicate-header convention, so the test harness needs to render
         them somewhere for `html =~`/`has_element?` assertions to see
         them. --%>
    <div :if={assigns[:page_title]} id="test-page-title">{@page_title}</div>
    <div :if={assigns[:page_subtitle]} id="test-page-subtitle">{@page_subtitle}</div>
    <a :if={assigns[:page_section]} id="test-page-section" href={@page_section_path}>
      {@page_section}
    </a>
    {@inner_content}
    """
  end

  def render(_template, assigns) do
    ~H"""
    <html>
      <body>
        <h1>Error</h1>
        <pre>{inspect(assigns[:reason] || assigns[:conn])}</pre>
      </body>
    </html>
    """
  end
end
