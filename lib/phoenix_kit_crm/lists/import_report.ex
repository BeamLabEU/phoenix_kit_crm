defmodule PhoenixKitCRM.Lists.ImportReport do
  @moduledoc """
  Result of an import run (`PhoenixKitCRM.Lists.Import`).

  `rows` carries one entry per input row, in file order, for the eventual
  admin UI's expandable row detail (Stage C4b) — `line` is 1-based and
  counts the header row for CSV input, so it lines up with what a user sees
  if they open the file in a spreadsheet editor.
  """

  @type skip_reason ::
          :already_in_list | :unsubscribed | :no_email | :invalid_email | :duplicate_in_file

  @type row :: %{
          line: pos_integer(),
          email: String.t() | nil,
          outcome: :imported | :skipped,
          reason: skip_reason() | nil
        }

  @type t :: %__MODULE__{
          created: non_neg_integer(),
          added: non_neg_integer(),
          skipped: %{skip_reason() => non_neg_integer()},
          rows: [row()]
        }

  defstruct created: 0,
            added: 0,
            skipped: %{
              already_in_list: 0,
              unsubscribed: 0,
              no_email: 0,
              invalid_email: 0,
              duplicate_in_file: 0
            },
            rows: []
end
