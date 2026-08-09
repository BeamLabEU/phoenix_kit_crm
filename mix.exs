defmodule PhoenixKitCRM.MixProject do
  use Mix.Project

  @version "0.4.1"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_crm"

  def project do
    [
      app: :phoenix_kit_crm,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

      # Hex
      description:
        "CRM module for PhoenixKit — organization accounts, role-scoped user views, and per-user column configuration.",
      package: package(),

      # Dialyzer
      dialyzer: [plt_add_apps: [:phoenix_kit, :mix], ignore_warnings: ".dialyzer_ignore.exs"],

      # Docs
      name: "PhoenixKitCRM",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :gettext, :phoenix_kit]
    ]
  end

  def cli do
    [preferred_envs: [test: :test, "test.setup": :test, "test.reset": :test]]
  end

  # test/support/ is compiled only in :test so DataCase and TestRepo
  # don't leak into the published package.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        # Scan for retired Hex deps. Run via `cmd` so Hex bootstraps in a fresh
        # process — the hex.* archive tasks aren't resolvable via Mix.Task.run
        # inside an alias.
        "cmd mix hex.audit",
        "quality.ci"
      ],
      "test.setup": [
        "ecto.create --quiet -r PhoenixKitCRM.Test.Repo",
        "ecto.migrate -r PhoenixKitCRM.Test.Repo"
      ],
      "test.reset": [
        "ecto.drop --quiet -r PhoenixKitCRM.Test.Repo",
        "test.setup"
      ]
    ]
  end

  defp deps do
    [
      # PhoenixKit provides the Module behaviour, Settings API, RepoHelper,
      # Dashboard tabs, and the admin layout this module renders into.
      #
      # Stage-3 lists/import code (contact lists + `phoenix_kit_crm_lists`/
      # `phoenix_kit_crm_list_members`) requires core migration V152, first
      # published in phoenix_kit 1.7.203.
      #
      # The floor is now 1.7.219: `organizations_view`, `role_view` and
      # `contact_show_live` import `PhoenixKitWeb.Components.Core.RowLink`, and
      # that module first ships in 1.7.219 (verified by unpacking the published
      # tarballs — absent in 1.7.218, present in 1.7.219 and 1.7.220). Without
      # this, a clean checkout resolving an older core fails to compile with an
      # undefined `row_link/1`; the local suite only passed because it runs with
      # PHOENIX_KIT_PATH pointing at a core checkout.
      pk_dep(:phoenix_kit, "~> 1.7 and >= 1.7.219"),

      # Hard, compile-time dep for the contact profile's Comments tab
      # (`use PhoenixKitComments.Embed` + CommentsComponent). Runtime-gated on
      # the module's admin toggle, so the tab hides when comments is disabled.
      # 0.2.6 is the floor: that is the release that first published
      # `PhoenixKitComments.Embed`. The `use` is unguarded, so a resolution
      # anywhere in 0.2.0–0.2.5 fails to compile in the consumer's build.
      pk_dep(:phoenix_kit_comments, "~> 0.2.6"),

      # Per-module i18n — own Gettext backend for sidebar tab labels.
      {:gettext, "~> 1.0"},

      # LiveView is needed for the admin pages.
      {:phoenix_live_view, "~> 1.1"},

      # Ecto for the role-settings and per-user view-config schemas.
      {:ecto_sql, "~> 3.13"},

      # CSV parsing for the contact-list import engine (Lists.Import). Pure
      # Elixir, no NIFs — already resolved transitively via phoenix_kit, so
      # declaring it directly here is zero extra footprint. XLSX support was
      # evaluated (xlsxir) and deferred: it's unmaintained since 2019.
      {:nimble_csv, "~> 1.2"},

      # Optional: add ex_doc for generating documentation
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},

      # Code quality
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},

      # `Phoenix.LiveViewTest` parses HTML via `lazy_html` for `element/2`,
      # `render(view) =~ "..."`, etc. Test-only.
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  # A phoenix_kit* dependency that can be swapped for a local checkout by
  # exporting <APP>_PATH (e.g. `PHOENIX_KIT_PATH=../phoenix_kit mix test`) so the
  # suite runs against unpublished local core (needed while the CRM tables
  # migration is unreleased). Unset → the published Hex pin, so publish/CI are
  # unaffected.
  defp pk_dep(app, requirement, opts \\ []) do
    env_var = String.upcase(Atom.to_string(app)) <> "_PATH"

    case System.get_env(env_var) do
      nil when opts == [] -> {app, requirement}
      nil -> {app, requirement, opts}
      path -> {app, [path: path, override: true] ++ opts}
    end
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitCRM",
      # Tags in this repo are bare version numbers, not v-prefixed — a "v" ref
      # points at a tag that does not exist and 404s every HexDocs source link.
      source_ref: @version
    ]
  end
end
