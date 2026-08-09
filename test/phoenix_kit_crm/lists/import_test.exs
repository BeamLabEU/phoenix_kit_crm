defmodule PhoenixKitCRM.Lists.ImportTest do
  use PhoenixKitCRM.DataCase, async: true

  alias PhoenixKitCRM.Lists
  alias PhoenixKitCRM.Lists.{Import, ImportReport}
  alias PhoenixKitCRM.Schemas.{Contact, ListMember}

  defp list_fixture(attrs \\ %{}) do
    {:ok, list} =
      Lists.create_list(
        Map.merge(%{"name" => "Newsletter", "slug" => "newsletter-#{unique_int()}"}, attrs)
      )

    list
  end

  defp unique_int, do: System.unique_integer([:positive])

  describe "import_csv/3" do
    test "creates a contact + membership per valid row, maps case-insensitive headers" do
      list = list_fixture()

      csv = """
      Email,Name,Company,Locale
      alice@example.com,Alice Wonder,Acme,en
      bob@example.com,Bob Builder,,de
      """

      report = Import.import_csv(csv, list)

      assert report.created == 2
      assert report.added == 2

      assert report.skipped == %{
               already_in_list: 0,
               unsubscribed: 0,
               no_email: 0,
               invalid_email: 0,
               duplicate_in_file: 0
             }

      assert length(report.rows) == 2
      assert Enum.all?(report.rows, &(&1.outcome == :imported))

      members = Lists.list_members(list)
      assert length(members) == 2

      alice = Enum.find(members, &(&1.email == "alice@example.com"))
      assert alice.contact.name == "Alice Wonder"
      assert alice.contact.locale == "en"
      assert alice.contact.metadata["import_company"] == "Acme"
      assert alice.contact.metadata["source"] == "import"
      assert alice.source == "import"

      bob = Enum.find(members, &(&1.email == "bob@example.com"))
      assert bob.contact.locale == "de"
      refute Map.has_key?(bob.contact.metadata, "import_company")
    end

    test "falls back to email as name when the name column is blank" do
      list = list_fixture()
      csv = "email,name\nnoname@example.com,\n"

      report = Import.import_csv(csv, list)
      assert report.created == 1

      [member] = Lists.list_members(list)
      assert member.contact.name == "noname@example.com"
    end

    test "strips a UTF-8 BOM before parsing headers" do
      list = list_fixture()
      bom = <<0xEF, 0xBB, 0xBF>>
      csv = bom <> "email\nbom@example.com\n"

      report = Import.import_csv(csv, list)
      assert report.created == 1
      assert [%{email: "bom@example.com", outcome: :imported}] = report.rows
    end

    test "handles CRLF line endings and quoted fields with embedded commas" do
      list = list_fixture()
      csv = "email,name\r\nquoted@example.com,\"Doe, Jane\"\r\n"

      report = Import.import_csv(csv, list)
      assert report.created == 1

      [member] = Lists.list_members(list)
      assert member.contact.name == "Doe, Jane"
    end

    test "imports unicode email addresses" do
      list = list_fixture()
      csv = "email\nüser@münchen.example\n"

      report = Import.import_csv(csv, list)
      assert report.created == 1
      assert [%{email: "üser@münchen.example", outcome: :imported}] = report.rows
    end

    test "skips a row with no email" do
      list = list_fixture()
      csv = "email,name\n,No Email\n"

      report = Import.import_csv(csv, list)
      assert report.created == 0
      assert report.skipped.no_email == 1
      assert [%{outcome: :skipped, reason: :no_email, email: nil}] = report.rows
    end

    test "skips a row with a malformed email" do
      list = list_fixture()
      csv = "email\nnot-an-email\n"

      report = Import.import_csv(csv, list)
      assert report.created == 0
      assert report.skipped.invalid_email == 1
    end

    test "skips the second row of a shared mailbox (same email, different names)" do
      list = list_fixture()

      csv = """
      email,name
      shared@example.com,Person One
      shared@example.com,Person Two
      """

      report = Import.import_csv(csv, list)
      assert report.created == 1
      assert report.skipped.duplicate_in_file == 1

      assert [
               %{outcome: :imported},
               %{outcome: :skipped, reason: :duplicate_in_file}
             ] = report.rows

      [member] = Lists.list_members(list)
      assert member.contact.name == "Person One"
    end

    test "drops an unrecognized locale format instead of skipping the row" do
      list = list_fixture()
      csv = "email,locale\ngoodrow@example.com,not-a-locale\n"

      report = Import.import_csv(csv, list)
      assert report.created == 1

      [member] = Lists.list_members(list)
      refute member.contact.locale
    end

    test "unrecognized columns are ignored" do
      list = list_fixture()
      csv = "email,phone\nignored@example.com,555-1234\n"

      report = Import.import_csv(csv, list)
      assert report.created == 1
    end

    test "empty content returns an empty report" do
      list = list_fixture()
      assert Import.import_csv("", list) == %ImportReport{}
    end
  end

  describe "import_text/3" do
    test "imports one email per line, ignoring blank lines" do
      list = list_fixture()
      text = "one@example.com\n\ntwo@example.com\n   \nthree@example.com\n"

      report = Import.import_text(text, list)
      assert report.created == 3
      assert report.added == 3
    end

    test "handles CRLF and a leading BOM" do
      list = list_fixture()
      bom = <<0xEF, 0xBB, 0xBF>>
      text = bom <> "crlf1@example.com\r\ncrlf2@example.com\r\n"

      report = Import.import_text(text, list)
      assert report.created == 2
    end

    test "invalid lines are skipped as invalid_email" do
      list = list_fixture()
      text = "good@example.com\nnot an email\n"

      report = Import.import_text(text, list)
      assert report.created == 1
      assert report.skipped.invalid_email == 1
    end
  end

  describe "idempotency and unsubscribed classification" do
    test "re-importing the same file is a no-op: zero new contacts, everything skipped as already_in_list" do
      list = list_fixture()
      csv = "email,name\na@example.com,A\nb@example.com,B\n"

      first = Import.import_csv(csv, list)
      assert first.created == 2

      contact_count_before = Repo.aggregate(Contact, :count, :uuid)

      second = Import.import_csv(csv, list)
      assert second.created == 0
      assert second.added == 0
      assert second.skipped.already_in_list == 2

      assert Repo.aggregate(Contact, :count, :uuid) == contact_count_before
    end

    test "classifies a removed membership's held email slot as :unsubscribed, not :already_in_list" do
      list = list_fixture()
      csv = "email,name\nremoved@example.com,Removed Person\n"

      Import.import_csv(csv, list)
      [member] = Lists.list_members(list)
      {:ok, _} = Lists.remove_from_list(member)

      report = Import.import_csv(csv, list)
      assert report.created == 0
      assert report.skipped.unsubscribed == 1
      assert report.skipped.already_in_list == 0
    end

    # Cross-feature regression for the Lists.add_contact_to_list/3
    # reactivate-on-add fix: it must not leak into import. A removed
    # member's email slot should still block a NEW contact, the removed
    # member itself must stay untouched, and no orphan contact is created.
    test "removed member is not reactivated by an import row sharing its email" do
      list = list_fixture()
      csv = "email,name\nremoved@example.com,Removed Person\n"

      Import.import_csv(csv, list)
      [original_member] = Lists.list_members(list)
      {:ok, removed_member} = Lists.remove_from_list(original_member)
      assert removed_member.status == "removed"

      contact_count_before = Repo.aggregate(Contact, :count, :uuid)

      report = Import.import_csv(csv, list)
      assert report.created == 0
      assert report.added == 0
      assert report.skipped.unsubscribed == 1

      # Import always creates a brand-new contact per row, so
      # add_new_contact_to_list/3 always calls add_contact_to_list/3 with a
      # contact that has never had a row for this list — get_member/2 there
      # is always nil, so it can only ever take the plain-insert path, never
      # the reactivate path. The pre-existing removed member must therefore
      # be left exactly as it was:
      still_removed = Repo.get!(ListMember, removed_member.uuid)
      assert still_removed.status == "removed"
      assert still_removed.unsubscribed_at == removed_member.unsubscribed_at

      # ...and the transaction rollback on the email-uniqueness violation
      # must still mean no orphan contact for the skipped row:
      assert Repo.aggregate(Contact, :count, :uuid) == contact_count_before
    end

    test "does not create an orphan contact on a re-import" do
      list = list_fixture()
      csv = "email,name\ndup@example.com,First\n"
      Import.import_csv(csv, list)

      count_before = Repo.aggregate(Contact, :count, :uuid)

      # Re-import: the batched members_by_email pre-check (see the query-cost
      # test below) now classifies this row as a KNOWN collision and skips it
      # before any write is attempted — no contact insert, so nothing to roll
      # back. A genuinely unknown-to-the-batch-lookup race would still hit
      # the transactional path and roll back on the same
      # idx_crm_list_members_list_email violation; either way, no orphan.
      Import.import_csv(csv, list)

      assert Repo.aggregate(Contact, :count, :uuid) == count_before
    end

    test "runs a bounded, constant number of queries on a re-import, not one write attempt per row" do
      list = list_fixture()

      csv =
        "email,name\n" <>
          Enum.map_join(1..300, "\n", fn n -> "dup#{n}@example.com,Dup #{n}" end)

      first = Import.import_csv(csv, list)
      assert first.created == 300

      # Before the batched pre-check, every one of these 300 rows would have
      # attempted its own contact INSERT inside a transaction, only to hit
      # idx_crm_list_members_list_email and roll back — 300 write attempts
      # for a file that changes nothing. The batched members_by_email lookup
      # now classifies all of them from ONE query, so the query count stays
      # flat regardless of row count.
      query_count =
        count_repo_queries(fn ->
          second = Import.import_csv(csv, list)
          assert second.created == 0
          assert second.skipped.already_in_list == 300
        end)

      assert query_count <= 3
    end
  end

  describe "ImportReport" do
    test "default struct has zeroed counters and the full skip-reason map" do
      assert %ImportReport{created: 0, added: 0, rows: []} = %ImportReport{}
      assert map_size(%ImportReport{}.skipped) == 5
    end
  end

  describe "parse_csv_rows/1 and parse_text_rows/1" do
    test "parse without touching the database" do
      list = list_fixture()
      count_before = Repo.aggregate(Contact, :count, :uuid)

      csv_rows = Import.parse_csv_rows("email,name\na@example.com,A\n")
      text_rows = Import.parse_text_rows("b@example.com\n")

      assert csv_rows == [
               {2,
                %{"email" => "a@example.com", "name" => "A", "company" => nil, "locale" => nil}}
             ]

      assert text_rows == [
               {1,
                %{"email" => "b@example.com", "name" => nil, "company" => nil, "locale" => nil}}
             ]

      assert Lists.list_members(list) == []
      assert Repo.aggregate(Contact, :count, :uuid) == count_before
    end

    test "return [] for malformed CSV instead of raising NimbleCSV.ParseError" do
      # Unterminated quoted field — NimbleCSV raises on this by default.
      assert Import.parse_csv_rows("email,name\n\"unterminated@example.com,A\n") == []
    end

    test "return [] for non-UTF-8 content instead of raising" do
      # A Windows-1252/Latin-1 export (Excel's default in many locales) —
      # 0xE9 is "é" in Latin-1, invalid as standalone UTF-8.
      assert Import.parse_csv_rows(<<"email,name\njos", 0xE9, "@example.com,Jos", 0xE9, "\n">>) ==
               []

      assert Import.parse_text_rows(<<"jos", 0xE9, "@example.com\n">>) == []
    end
  end

  describe "preview_rows/2" do
    test "classifies every row without writing anything" do
      list = list_fixture()
      count_before = Repo.aggregate(Contact, :count, :uuid)

      rows =
        Import.parse_csv_rows("""
        email,name
        good@example.com,Good Row
        good@example.com,Duplicate
        not-an-email,Bad Row
        ,No Email
        """)

      report = Import.preview_rows(rows, list)

      assert report.created == 1
      assert report.added == 1
      assert report.skipped.duplicate_in_file == 1
      assert report.skipped.invalid_email == 1
      assert report.skipped.no_email == 1
      assert length(report.rows) == 4

      # nothing was actually written
      assert Lists.list_members(list) == []
      assert Repo.aggregate(Contact, :count, :uuid) == count_before
    end

    test "detects already_in_list vs unsubscribed via a read-only lookup" do
      list = list_fixture()

      Import.import_csv("email,name\nactive@example.com,Active\n", list)
      Import.import_csv("email,name\nremoved@example.com,Removed\n", list)

      [removed_member] =
        Enum.filter(Lists.list_members(list), &(&1.email == "removed@example.com"))

      {:ok, _} = Lists.remove_from_list(removed_member)

      contact_count_before = Repo.aggregate(Contact, :count, :uuid)

      rows =
        Import.parse_csv_rows("""
        email,name
        active@example.com,Active Again
        removed@example.com,Removed Again
        """)

      report = Import.preview_rows(rows, list)

      assert report.created == 0
      assert report.skipped.already_in_list == 1
      assert report.skipped.unsubscribed == 1

      # a preview is read-only
      assert Repo.aggregate(Contact, :count, :uuid) == contact_count_before
    end

    test "classifies a mixed file correctly through the batched members_by_email/2 lookup" do
      list = list_fixture()

      Import.import_csv("email,name\nactive@example.com,Active\n", list)
      Import.import_csv("email,name\nremoved@example.com,Removed\n", list)

      [removed_member] =
        Enum.filter(Lists.list_members(list), &(&1.email == "removed@example.com"))

      {:ok, _} = Lists.remove_from_list(removed_member)

      rows =
        Import.parse_csv_rows("""
        email,name
        new@example.com,Would Import
        active@example.com,Already In List
        removed@example.com,Unsubscribed Slot
        not-an-email,Invalid
        ,No Email
        new@example.com,Duplicate Of Row One
        """)

      report = Import.preview_rows(rows, list)

      assert report.created == 1
      assert report.added == 1

      assert report.skipped == %{
               already_in_list: 1,
               unsubscribed: 1,
               no_email: 1,
               invalid_email: 1,
               duplicate_in_file: 1
             }

      by_line = Map.new(report.rows, &{&1.line, &1})
      assert by_line[2].outcome == :imported

      assert by_line[3] == %{
               line: 3,
               email: "active@example.com",
               outcome: :skipped,
               reason: :already_in_list
             }

      assert by_line[4] == %{
               line: 4,
               email: "removed@example.com",
               outcome: :skipped,
               reason: :unsubscribed
             }

      assert by_line[5].reason == :invalid_email
      assert by_line[6] == %{line: 6, email: nil, outcome: :skipped, reason: :no_email}
      assert by_line[7].reason == :duplicate_in_file
    end

    test "runs a bounded, constant number of queries regardless of file size" do
      list = list_fixture()

      # A handful of pre-existing collisions (one active, one removed) plus
      # many fresh rows — if members_by_email/2's batching ever regressed
      # back to a per-row Lists.get_member_by_email/2 call, this query count
      # would scale with row count instead of staying flat.
      Import.import_csv("email,name\nactive@example.com,Active\n", list)
      Import.import_csv("email,name\nremoved@example.com,Removed\n", list)

      [removed_member] =
        Enum.filter(Lists.list_members(list), &(&1.email == "removed@example.com"))

      {:ok, _} = Lists.remove_from_list(removed_member)

      fresh_rows =
        Enum.map_join(1..300, "\n", fn n -> "fresh#{n}@example.com,Fresh #{n}" end)

      csv = "email,name\nactive@example.com,Again\nremoved@example.com,Again\n" <> fresh_rows

      rows = Import.parse_csv_rows(csv)
      query_count = count_repo_queries(fn -> Import.preview_rows(rows, list) end)

      assert query_count <= 3
    end
  end

  # Counts Ecto query telemetry events (PhoenixKitCRM.Test.Repo's default
  # prefix) fired while running `fun`. Used to prove preview_rows/2 issues a
  # small, constant number of queries rather than one per row.
  #
  # :telemetry.attach is process-global, not scoped to the caller — under
  # async: true, other tests' concurrently-running queries fire the same
  # event and would inflate the count. Telemetry handlers run synchronously
  # in whichever process executes :telemetry.execute (i.e. whichever process
  # issued the query), so filtering on self() inside the handler isolates
  # counts to queries issued by this test's own process.
  defp count_repo_queries(fun) do
    handler_id = "count-repo-queries-#{inspect(self())}-#{System.unique_integer()}"
    counter = :counters.new(1, [])
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:phoenix_kit_crm, :test, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == test_pid, do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    :counters.get(counter, 1)
  end

  describe "run_chunk/4" do
    test "processing in chunks matches a single-shot import_csv/3 run" do
      list_a = list_fixture()
      list_b = list_fixture()

      csv = """
      email,name
      one@example.com,One
      two@example.com,Two
      three@example.com,Three
      """

      whole_report = Import.import_csv(csv, list_a)

      rows = Import.parse_csv_rows(csv)
      [chunk1, chunk2] = Enum.chunk_every(rows, 2)

      {report_1, acc_1} = Import.run_chunk(chunk1, list_b, [], Import.new_accumulator())
      {report_2, _acc_2} = Import.run_chunk(chunk2, list_b, [], {report_1, acc_1})

      assert report_2.created == whole_report.created
      assert report_2.added == whole_report.added
      assert report_2.skipped == whole_report.skipped
      assert length(report_2.rows) == length(whole_report.rows)

      assert length(Lists.list_members(list_b)) == 3
    end

    test "duplicate_in_file detection carries across chunk boundaries" do
      list = list_fixture()

      rows =
        Import.parse_csv_rows("""
        email,name
        shared@example.com,First
        other@example.com,Other
        shared@example.com,Second
        """)

      [chunk1, chunk2] = [Enum.take(rows, 2), Enum.drop(rows, 2)]

      {report_1, acc_1} = Import.run_chunk(chunk1, list, [], Import.new_accumulator())
      {report_2, _acc_2} = Import.run_chunk(chunk2, list, [], {report_1, acc_1})

      assert report_2.created == 2
      assert report_2.skipped.duplicate_in_file == 1
      assert length(Lists.list_members(list)) == 2
    end
  end
end
