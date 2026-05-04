defmodule PhoenixKitCRMTest do
  use ExUnit.Case

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

    test "enabled?/0 returns a boolean" do
      assert is_boolean(PhoenixKitCRM.enabled?())
    end

    test "enable_system/0 and disable_system/0 are exported" do
      assert function_exported?(PhoenixKitCRM, :enable_system, 0)
      assert function_exported?(PhoenixKitCRM, :disable_system, 0)
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

  describe "Paths" do
    alias PhoenixKitCRM.Paths

    test "index/0 points to the CRM admin page" do
      assert String.ends_with?(Paths.index(), "/admin/crm")
    end

    test "settings/0 points to the CRM settings page" do
      assert String.ends_with?(Paths.settings(), "/admin/settings/crm")
    end
  end
end
