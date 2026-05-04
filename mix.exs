defmodule PhoenixKitCRM.MixProject do
  use Mix.Project

  @version "0.1.0"
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
        "CRM module for PhoenixKit — companies, role-scoped views, and per-user column configuration.",
      package: package(),

      # Dialyzer
      dialyzer: [plt_add_apps: [:phoenix_kit]],

      # Docs
      name: "PhoenixKitCRM",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :phoenix_kit]
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
      precommit: ["compile", "quality"],
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
      {:phoenix_kit, "~> 1.7"},

      # LiveView is needed for the admin pages.
      {:phoenix_live_view, "~> 1.1"},

      # Ecto for the role-settings and per-user view-config schemas.
      {:ecto_sql, "~> 3.13"},

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

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitCRM",
      source_ref: "v#{@version}"
    ]
  end
end
