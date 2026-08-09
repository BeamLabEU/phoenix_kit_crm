defmodule PhoenixKitCRMTest do
  use ExUnit.Case

  alias Ecto.Adapters.SQL.Sandbox

  # Most tests here are pure (callback shapes, tab config). A few hit the DB —
  # enabled?/0 (settings table) and Paths.index/settings (Routes.path reads
  # languages_enabled). Those are tagged :integration and get a sandbox
  # connection here; without it they flaked, only passing when the settings cache
  # happened to be warm.
  setup context do
    if context[:integration] do
      pid = Sandbox.start_owner!(PhoenixKitCRM.Test.Repo, shared: true)
      on_exit(fn -> Sandbox.stop_owner(pid) end)
    end

    :ok
  end

  describe "behaviour implementation" do
    test "implements PhoenixKit.Module" do
      behaviours =
        PhoenixKitCRM.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert PhoenixKit.Module in behaviours
    end

    test "has @phoenix_kit_module attribute for auto-discovery" do
      attrs = PhoenixKitCRM.__info__(:attributes)
      assert Keyword.get(attrs, :phoenix_kit_module) == [true]
    end
  end

  describe "required callbacks" do
    test "module_key/0 returns \"crm\"" do
      assert PhoenixKitCRM.module_key() == "crm"
    end

    test "module_name/0 returns \"CRM\"" do
      assert PhoenixKitCRM.module_name() == "CRM"
    end

    @tag :integration
    test "enabled?/0 returns a boolean" do
      assert is_boolean(PhoenixKitCRM.enabled?())
    end

    test "enable_system/0 and disable_system/0 are exported" do
      assert function_exported?(PhoenixKitCRM, :enable_system, 0)
      assert function_exported?(PhoenixKitCRM, :disable_system, 0)
    end

    test "version/0 matches the mix.exs package version" do
      # Guards against the two version sources (mix.exs @version and this
      # callback) drifting apart — they report the same string to the admin UI.
      assert PhoenixKitCRM.version() == Mix.Project.config()[:version]
    end
  end

  describe "permission_metadata/0" do
    test "key matches module_key and icon uses hero- prefix" do
      meta = PhoenixKitCRM.permission_metadata()
      assert meta.key == PhoenixKitCRM.module_key()
      assert String.starts_with?(meta.icon, "hero-")
      assert is_binary(meta.label)
      assert is_binary(meta.description)
    end
  end

  describe "admin_tabs/0" do
    test "returns tabs with matching permission and hyphenated paths" do
      tabs = PhoenixKitCRM.admin_tabs()
      assert is_list(tabs)
      refute Enum.empty?(tabs)

      for tab <- tabs do
        assert tab.permission == PhoenixKitCRM.module_key()
        refute String.contains?(tab.path, "_")
      end
    end

    test "main tab points to CRMLive" do
      [main | _] = PhoenixKitCRM.admin_tabs()
      assert main.id == :admin_crm
      assert main.group == :admin_modules
      assert {PhoenixKitCRM.Web.CRMLive, :index} = main.live_view
    end
  end

  describe "settings_tabs/0" do
    test "exposes a CRM settings tab pointing to SettingsLive" do
      [tab] = PhoenixKitCRM.settings_tabs()
      assert tab.id == :admin_settings_crm
      assert tab.permission == PhoenixKitCRM.module_key()
      assert {PhoenixKitCRM.Web.SettingsLive, :index} = tab.live_view
    end
  end

  # The projects hub discovers this by name and normalizes it defensively: an
  # invalid tab or config field is DROPPED with a `Logger.warning` and the
  # extension still registers, so a typo here costs the Client tab (or its
  # company picker) silently, in the host app, at runtime. These assertions
  # mirror the hub's normalizer (`PhoenixKitProjects.Extensions.Extension`)
  # without depending on the projects package — the contract is one-way.
  describe "phoenix_kit_project_extensions/0" do
    @schema_types [:string, :text, :number, :boolean, :select]

    test "contributes the Client extension keyed to this module" do
      [ext] = PhoenixKitCRM.phoenix_kit_project_extensions()

      assert ext.key == "crm_client"
      assert ext.name == "Client"
      # Drives the hub's permission gate: a tab re-exporting CRM data requires
      # the CRM permission, not the viewer's projects permission.
      assert ext.module_key == PhoenixKitCRM.module_key()
      assert ext.default_enabled == false
      # Read-only tab: the hub derives "can_write" from the first non-:view
      # action, so declaring one here would hand it a write surface it lacks.
      assert ext.permission_actions == [:view]
    end

    test "every tab survives the hub's tab normalizer" do
      [ext] = PhoenixKitCRM.phoenix_kit_project_extensions()
      refute Enum.empty?(ext.tabs)

      for tab <- ext.tabs do
        assert is_binary(tab.key) and tab.key != ""
        assert is_binary(tab.label) and tab.label != ""
        assert is_atom(tab.lv) and Code.ensure_loaded?(tab.lv)
        # Off-router mountable is the hub's hard requirement for a contributed
        # tab: a handle_params/3 export blocks `live_render`.
        refute function_exported?(tab.lv, :handle_params, 3)
      end
    end

    test "config fields use supported types and a resolvable option source" do
      [ext] = PhoenixKitCRM.phoenix_kit_project_extensions()

      for field <- ext.config_schema do
        assert is_binary(field.key) and field.key != ""
        assert field.type in @schema_types

        if field.type == :select do
          # Lazy options are `{module, fun}`, 0-arity; anything else resolves
          # to an empty select and the admin can't link a client at all.
          assert {module, fun} = field.options
          assert Code.ensure_loaded?(module) and function_exported?(module, fun, 0)
        end
      end
    end
  end

  describe "Routes" do
    alias PhoenixKit.Dashboard.Tab

    # Core turns every tab carrying a `live_view:` into a route, and splices
    # `PhoenixKitCRM.Routes` in alongside those in the same live_session. A path
    # declared in both places compiles the host router with "this clause cannot
    # match because a previous clause matches the same pattern", which fails a
    # host running `mix compile --warnings-as-errors` — that was PR #18, for
    # `/admin/crm/comparison`. Only hand-written *parameterized/detail* routes
    # belong here; list-index paths come from the tabs.
    test "admin_routes/0 declares no path a tab already generates" do
      tab_paths =
        [{:admin, PhoenixKitCRM.admin_tabs()}, {:settings, PhoenixKitCRM.settings_tabs()}]
        |> Enum.flat_map(fn {context, tabs} ->
          tabs
          |> Enum.filter(& &1.live_view)
          |> Enum.map(&Tab.resolve_path(&1, context).path)
        end)
        |> MapSet.new()

      declared = declared_paths(PhoenixKitCRM.Routes.admin_routes())
      # Guards the guard: an extraction that silently returned [] would pass.
      refute Enum.empty?(declared)

      for path <- declared do
        refute path in tab_paths,
               "#{path} is declared in PhoenixKitCRM.Routes and also generated from a tab"
      end
    end

    test "admin_routes/0 and admin_locale_routes/0 cover the same paths" do
      assert declared_paths(PhoenixKitCRM.Routes.admin_routes()) ==
               declared_paths(PhoenixKitCRM.Routes.admin_locale_routes())
    end
  end

  describe "Paths" do
    alias PhoenixKitCRM.Paths

    @tag :integration
    test "index/0 points to the CRM admin page" do
      assert String.ends_with?(Paths.index(), "/admin/crm")
    end

    @tag :integration
    test "settings/0 points to the CRM settings page" do
      assert String.ends_with?(Paths.settings(), "/admin/settings/crm")
    end
  end

  # The route builders return a quoted block of `live/4` calls (core splices it
  # into the host router), so the paths are string literals in the AST.
  defp declared_paths(ast) do
    {_ast, paths} =
      Macro.prewalk(ast, [], fn
        {:live, _meta, [path | _rest]} = node, acc when is_binary(path) -> {node, [path | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(paths)
  end
end
