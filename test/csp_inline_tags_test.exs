defmodule PhoenixKitCRM.CSPInlineTagsTest do
  @moduledoc """
  The pages of this module work under a host Content-Security-Policy that allows inline code
  by nonce only (`script-src 'self' 'nonce-…'`): the module renders no inline `<style>` /
  `<script>` and no inline event handler (no nonce can cover an attribute; a `phx-` binding or
  a hook in the module's bundle does that work). An inline tag added later must carry the
  page's nonce through a feature-detecting `PhoenixKitCRM.Web.CSP` helper; see AGENTS.md,
  "Content-Security-Policy".

  Modelled on core's `test/phoenix_kit_web/csp_inline_tags_test.exs`.
  """
  use ExUnit.Case, async: true

  @doc_heredoc ~r/@(?:moduledoc|doc|typedoc|shortdoc)\s+(?:~[sS])?"""\n.*?\n\s*"""/s

  defp bundles do
    Enum.map(PhoenixKitCRM.js_sources(), &Path.join("priv", &1.file))
  end

  @tag_opening ~r/<(?:script|style)(?=[\s>])(?:[^>"']|"[^"]*"|'[^']*')*>/i
  @attribute ~r/\s+([^\s=\/>]+)(?:\s*=\s*("[^"]*"|'[^']*'|\{[^}]*\}|[^\s>]+))?/

  # Exempt: a colocated hook (`<script :type={Phoenix.LiveView.ColocatedHook}>`) is taken out
  # of the template by the compiler and is never rendered as an inline tag.
  test "no inline <script> or <style> in lib/ is written without a nonce" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          {opening, number} <- tag_openings(path),
          not allowed_opening?(opening),
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline tags without a nonce (feature-detect `PhoenixKitWeb.CSP.nonce/1`, " <>
             "see AGENTS.md, \"Content-Security-Policy\"):\n" <> Enum.join(offenders, "\n")
  end

  defp allowed_opening?(opening) do
    script? = String.match?(opening, ~r/^<script\b/i)
    kind = if script?, do: "script", else: "style"

    Enum.any?(Regex.scan(@attribute, opening), fn
      [_, name, value] ->
        case String.downcase(name) do
          "src" -> script?
          ":type" -> script? and value == "{Phoenix.LiveView.ColocatedHook}"
          "nonce" -> value == "{PhoenixKitCRM.Web.CSP.nonce(:#{kind})}"
          _ -> false
        end

      _ ->
        false
    end)
  end

  test "tag exemptions require the appropriate attribute and tag" do
    assert allowed_opening?(~s(<script src="/assets/app.js">))
    assert allowed_opening?(~s[<style nonce={PhoenixKitCRM.Web.CSP.nonce(:style)}>])
    assert allowed_opening?(~s[<script :type={Phoenix.LiveView.ColocatedHook}>])
    refute allowed_opening?(~s(<style src="/assets/app.css">))
    refute allowed_opening?(~s(<script data-src="/assets/app.js">))
    refute allowed_opening?(~s(<script title="has src='/assets/app.js'">))
    refute allowed_opening?(~s[<style nonce={PhoenixKitCRM.Web.CSP.nonce(:script)}>])
  end

  # `nonce={…}` is HEEx. In a plain string it is rendered as written, a literal attribute
  # the browser cannot match.
  test "a `nonce={…}` attribute in an .ex file sits inside a ~H template" do
    offenders =
      for path <- Path.wildcard("lib/**/*.ex"),
          lines = path |> File.read!() |> code_lines(),
          {line, number} <- lines,
          line =~ "nonce={PhoenixKitCRM.Web.CSP",
          not in_heex?(lines, number),
          do: "#{path}:#{number}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  # The nearest heredoc opener above the line is a `~H`.
  defp in_heex?(lines, number) do
    lines
    |> Enum.take(number - 1)
    |> Enum.reverse()
    |> Enum.find(fn {line, _} -> line =~ ~s(""") end)
    |> case do
      {opener, _} -> opener =~ ~s(~H""")
      nil -> false
    end
  end

  # Only the helper names core's module: it is newer than the core floor, and a direct call
  # anywhere else would not compile against the floor.
  test "PhoenixKitWeb.CSP is called through the feature-detecting helper only" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          path != "lib/phoenix_kit_crm/web/csp.ex",
          {line, number} <- path |> File.read!() |> code_lines(),
          not (line =~ ~r/^\s*#/),
          line =~ ~r/PhoenixKitWeb\.CSP\.[a-z_]+\(/ or
            line =~ ~r/on_mount\(?\s*PhoenixKitWeb\.CSP\b/,
          do: "#{path}:#{number}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  # The projects hub embeds the Client tab with `live_render/3`: a process of its own that
  # skips the live session's `on_mount`. The hub puts the nonces in the embed session, and
  # `use PhoenixKitWeb, :live_view` carries core's `on_mount` that restores them (on a core
  # that has nonce support). A view on bare `Phoenix.LiveView` would lose them.
  test "the embedded Client tab gets core's live_view wiring" do
    source = File.read!("lib/phoenix_kit_crm/web/project_client_live.ex")
    assert source =~ ~r/^\s*use PhoenixKitWeb, :live_view\b/m
  end

  # `onclick="…"`, `onclick='…'`, `onclick={…}`, and the same with spaces around `=` for the
  # events a browser knows (a bare `on\w+ =` would also match Elixir like `only = "x"`).
  @events ~w(click dblclick change input submit reset invalid select focus blur focusin focusout
             keydown keyup keypress load error scroll wheel resize toggle contextmenu copy cut
             paste drop) ++
            ~w(mousedown mouseup mouseover mouseout mousemove mouseenter mouseleave) ++
            ~w(touchstart touchend touchmove pointerdown pointerup pointermove) ++
            ~w(dragstart dragend dragover dragenter dragleave animationend transitionend)
  @handler Regex.compile!(
             "\\son(?!ly=)[a-z]+=[\"'{]|\\son(?:#{Enum.join(@events, "|")})\\s*=\\s*[\"'{]",
             "i"
           )
  @js_url ~r/\b(?:href|src|action|formaction)\s*=\s*["'{]\s*["']?\s*javascript:/i

  test "no markup in lib/ carries an inline event handler" do
    offenders =
      for path <- Path.wildcard("lib/**/*.{ex,heex}"),
          {line, number} <- path |> File.read!() |> code_lines(),
          not (line =~ ~r/^\s*(#|iex>|\.\.\.>)/),
          line =~ @handler or line =~ @js_url,
          do: "#{path}:#{number}"

    assert offenders == [],
           "inline handlers (no nonce covers them; use a `phx-` binding or a hook in the " <>
             "module's bundle):\n" <> Enum.join(offenders, "\n")
  end

  test "the handler pattern matches what it is meant to" do
    assert ~s[<ul onclick="x()">] =~ @handler
    assert ~s(<div onclick={@x}>) =~ @handler
    assert ~s(<img ONERROR={@x}>) =~ @handler
    assert ~s(<img onerror = 'x'>) =~ @handler
    assert ~s[<a href="javascript:void(0)">] =~ @js_url
    refute ~s(<button phx-click="go">) =~ @handler
    refute ~s(<.table only={@only}>) =~ @handler
    refute ~s(only = "x") =~ @handler
  end

  test "the bundle builds no markup with an inline event handler" do
    offenders =
      for {path, line, number} <- bundle_lines(),
          line =~ ~r/\son[a-z]+\s*=\s*\\?["']/i or line =~ ~r/javascript:/i,
          do: "#{path}:#{number}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  # All executable code and styles in the CRM bundle are shipped as static assets.
  test "the bundle creates no <style>/<script> and evaluates no strings" do
    offenders =
      for {path, line, number} <- bundle_lines(),
          problem = bundle_problem(line),
          do: "#{path}:#{number} #{problem}"

    assert offenders == [], Enum.join(offenders, "\n")
  end

  defp bundle_problem(line) do
    cond do
      line =~ ~r/createElement\s*\(\s*["'](?:style|script)["']\s*\)/i ->
        "creates a <style>/<script> element"

      line =~ ~r/["'`]<(?:style|script)\b/i ->
        "builds a <style>/<script> tag as a string"

      line =~ ~r/\beval\s*\(|new\s+Function\s*\(/ ->
        "evaluates a string"

      true ->
        nil
    end
  end

  test "all shipped JavaScript is registered for scanning" do
    assert Enum.sort(Path.wildcard("{lib,priv}/**/*.{js,mjs,cjs,jsx,ts,mts,cts,tsx}")) ==
             Enum.sort(bundles())
  end

  # The bundles' lines without their comment lines.
  defp bundle_lines do
    for path <- bundles(),
        {line, number} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
        not (line =~ ~r{^\s*(//|\*|/\*)}),
        do: {path, line, number}
  end

  # Every opening `<script …>` / `<style …>` of the file with the line it starts on.
  defp tag_openings(path) do
    source = path |> File.read!() |> markup_source()

    for [{start, length}] <- Regex.scan(@tag_opening, source, return: :index, capture: :first) do
      line = source |> binary_part(0, start) |> String.split("\n") |> length()
      {binary_part(source, start, length), line}
    end
  end

  # The source with what is not markup blanked, line numbers kept: documentation, HEEx
  # comments and Elixir comment lines (a tag there is prose).
  defp markup_source(source) do
    blank = fn text -> String.replace(text, ~r/[^\n]/, "") end

    source
    |> then(&Regex.replace(@doc_heredoc, &1, blank))
    |> then(&Regex.replace(~r/<%!--.*?--%>/s, &1, blank))
    |> then(&Regex.replace(~r/^[ \t]*#[^\n]*$/m, &1, ""))
  end

  defp code_lines(source) do
    @doc_heredoc
    |> Regex.replace(source, fn doc -> String.replace(doc, ~r/[^\n]/, "") end)
    |> String.split("\n")
    |> Enum.with_index(1)
  end
end
