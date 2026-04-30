# phoenix_kit_crm

CRM module for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit).

Currently a minimal skeleton: one empty admin LiveView and a settings page
with an enable/disable toggle. Built from the
[phoenix_kit_hello_world](https://github.com/BeamLabEU/phoenix_kit_hello_world)
template.

## Installation

Add to the host app's `mix.exs`:

```elixir
{:phoenix_kit_crm, path: "../phoenix_kit_crm"}
```

Then `mix deps.get`. The module appears in the admin Modules page and
sidebar automatically via `PhoenixKit.Module` auto-discovery.

## Routes

| Path                      | LiveView                          |
|---------------------------|-----------------------------------|
| `/admin/crm`              | `PhoenixKitCRM.Web.CRMLive`       |
| `/admin/settings/crm`     | `PhoenixKitCRM.Web.SettingsLive`  |

## Development

```sh
mix deps.get
mix compile
mix test
```
