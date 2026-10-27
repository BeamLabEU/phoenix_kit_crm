defmodule PhoenixKitCRM.Test.SiteOwner do
  @moduledoc """
  Registers the site's Owner before a test's own users.

  Core makes the FIRST registered user of a database the Owner, and every
  sandboxed test starts with none — so without this, the first fixture user
  a test registers is the Owner, which the CRM refuses to offer or link
  (`PhoenixKitCRM.AccountGuard`). Call `ensure!/0` in the setup of any test
  that links a registered account.
  """

  alias PhoenixKit.Users.Auth

  @spec ensure!() :: map()
  def ensure! do
    {:ok, owner} =
      Auth.register_user(%{
        "email" => "site-owner-#{System.unique_integer([:positive])}@example.test",
        "password" => "Sup3rSecret!24"
      })

    owner
  end
end
