defmodule PhoenixKitCRM.ActivityTest do
  @moduledoc """
  CRM logs through `PhoenixKit.Activity.log/3` under its module key, and
  reads the actor the way every module does (`PhoenixKitWeb.Actor`): the
  scope first — it used to read only the bare current user.
  """
  use PhoenixKitCRM.DataCase, async: false

  import PhoenixKitCRM.ActivityLogAssertions

  alias PhoenixKit.Users.Auth.{Scope, User}
  alias PhoenixKitCRM.Activity

  @scoped "019a0000-0000-7000-8000-00000000c001"
  @bare "019a0000-0000-7000-8000-00000000c002"

  test "log/2 writes a crm entry with the options" do
    resource = UUIDv7.generate()

    assert {:ok, _} =
             Activity.log("crm.company_updated",
               resource_type: "company",
               resource_uuid: resource,
               metadata: %{"name" => "Acme"}
             )

    assert_activity_logged("crm.company_updated",
      resource_uuid: resource,
      metadata_has: %{"name" => "Acme"}
    )
  end

  test "the actor is the scope's user, else the bare current user" do
    scope = %Scope{user: %User{uuid: @scoped}, authenticated?: true}

    assert Activity.actor_uuid(%{
             assigns: %{
               phoenix_kit_current_scope: scope,
               phoenix_kit_current_user: %User{uuid: @bare}
             }
           }) ==
             @scoped

    assert Activity.actor_opts(%{assigns: %{phoenix_kit_current_user: %User{uuid: @bare}}}) ==
             [actor_uuid: @bare]

    assert Activity.actor_opts(%{assigns: %{}}) == []
  end
end
