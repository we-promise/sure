require "test_helper"

class Family::TransactionTimestampRoundTripTest < ActiveSupport::TestCase
  setup do
    travel_to Time.utc(2026, 9, 22, 12)
    @source = families(:dylan_family)
    @target = families(:empty)
    @entry = entries(:transaction)
    @timestamp = Time.iso8601("2026-09-17T23:30:00.123456Z")
    @entry.update!(date: "2026-09-17", transacted_at: @timestamp)
  end

  test "CSV export and import preserve both date and timestamp" do
    csv = exported_files.fetch("transactions.csv")
    row = CSV.parse(csv, headers: true).find { |item| item["name"] == @entry.name }
    assert_equal "2026-09-17", row["date"]
    assert_equal @timestamp.iso8601(6), row["transacted_at"]

    account = @target.accounts.create!(name: "Restored", balance: 0, currency: "USD", accountable: Depository.new)
    @target.update!(timezone: "Europe/Paris")
    import = TransactionImport.create!(family: @target, account: account, raw_file_str: csv,
      date_col_label: "date", date_format: "auto", amount_col_label: "amount", name_col_label: "name",
      timestamp_col_label: "transacted_at", date_basis: "local", signage_convention: "inflows_negative")
    import.generate_rows_from_csv
    import.publish

    assert_equal "complete", import.status, import.error
    restored = import.entries.find_by!(name: @entry.name)
    assert_equal @entry.date, restored.date
    assert_equal @timestamp, restored.transacted_at
  end

  test "NDJSON restores split timestamps and explicit clear protection" do
    @entry.split!([ { name: "Split A", amount: @entry.amount / 2 }, { name: "Split B", amount: @entry.amount / 2 } ])
    cleared = @source.accounts.first.entries.create!(date: "2026-09-17", amount: 5, name: "Cleared time",
      currency: "USD", locked_attributes: { "transacted_at" => Time.current.iso8601 },
      entryable: Transaction.new(extra: { "csv" => { "transacted_at" => @timestamp.iso8601(6) } }))

    Family::DataImporter.new(@target, exported_files.fetch("all.ndjson")).import!
    restored = @target.entries.find_by!(name: @entry.name)
    assert_equal @entry.date, restored.date
    assert_equal @timestamp, restored.transacted_at
    assert_equal [ @timestamp ], restored.child_entries.distinct.pluck(:transacted_at)

    restored_clear = @target.entries.find_by!(name: cleared.name)
    assert_nil restored_clear.transacted_at
    assert restored_clear.locked?(:transacted_at)
    assert_equal @timestamp.iso8601(6), restored_clear.transaction.extra.dig("csv", "transacted_at")
  end

  test "NDJSON preserves source-date provenance when the accounting date differs" do
    @source.update!(timezone: "Europe/Paris")
    csv = "Date,Amount,Name\n2026-09-17T23:30:00Z,0,Synthetic backup merchant\n"
    source_import = TransactionImport.create!(family: @source, account: @entry.account, raw_file_str: csv,
      date_col_label: "Date", date_format: "auto", amount_col_label: "Amount", name_col_label: "Name",
      date_basis: "local", signage_convention: "inflows_negative")
    source_import.generate_rows_from_csv
    source_import.publish
    assert_equal "complete", source_import.status, source_import.error

    Family::DataImporter.new(@target, exported_files.fetch("all.ndjson")).import!
    restored = @target.entries.find_by!(name: "Synthetic backup merchant")
    assert_equal Date.new(2026, 9, 18), restored.date
    assert_equal "2026-09-17", restored.transaction.extra.dig("csv", "date")

    reimport = TransactionImport.create!(family: @target, account: restored.account, raw_file_str: csv,
      date_col_label: "Date", date_format: "auto", amount_col_label: "Amount", name_col_label: "Name",
      date_basis: "source", signage_convention: "inflows_negative")
    reimport.generate_rows_from_csv
    assert_no_difference "Entry.count" do
      reimport.publish
    end
    assert_equal "complete", reimport.status, reimport.error
    assert_equal restored.id, reimport.entries.first.id
    assert_equal Date.new(2026, 9, 18), restored.reload.date
  end

  test "NDJSON preserves a foreign Sure CSV ID for repeat imports" do
    foreign_id = SecureRandom.uuid
    csv = "Date,Amount,Name,Occurred,sure_entry_id\n2026-09-19,0,Synthetic external export,2026-09-19T10:45Z,#{foreign_id}\n"
    import = TransactionImport.create!(family: @source, account: @entry.account, raw_file_str: csv,
      date_col_label: "Date", date_format: "%Y-%m-%d", timestamp_col_label: "Occurred",
      amount_col_label: "Amount", name_col_label: "Name", signage_convention: "inflows_negative")
    import.generate_rows_from_csv
    import.publish
    assert_equal "complete", import.status, import.error

    Family::DataImporter.new(@target, exported_files.fetch("all.ndjson")).import!
    restored = @target.entries.find_by!(name: "Synthetic external export")
    assert_includes restored.transaction.extra.dig("csv", "sure_entry_ids"), foreign_id

    repeated = TransactionImport.create!(family: @target, account: restored.account, raw_file_str: csv,
      date_col_label: "Date", date_format: "%Y-%m-%d", timestamp_col_label: "Occurred",
      amount_col_label: "Amount", name_col_label: "Name", signage_convention: "inflows_negative")
    repeated.generate_rows_from_csv
    assert_no_difference "Entry.count" do
      repeated.publish
    end
    assert_equal "complete", repeated.status, repeated.error
    assert_equal restored.id, repeated.entries.first.id
  end

  test "NDJSON restores a native Sure CSV ID for corrected-export reimports" do
    source_csv = "Date,Amount,Name,Occurred\n2026-09-17,0,Synthetic backup merchant,2026-09-17T14:48:50Z\n"
    source_import = TransactionImport.create!(family: @source, account: @entry.account, raw_file_str: source_csv,
      date_col_label: "Date", date_format: "%Y-%m-%d", timestamp_col_label: "Occurred",
      amount_col_label: "Amount", name_col_label: "Name", signage_convention: "inflows_negative")
    source_import.generate_rows_from_csv
    source_import.publish
    assert_equal "complete", source_import.status, source_import.error
    entry = source_import.entries.first
    entry.update!(date: "2026-09-18", transacted_at: Time.utc(2026, 9, 17, 18))

    files = exported_files
    rows = CSV.parse(files.fetch("transactions.csv"), headers: true)
    native_csv = CSV.generate do |csv|
      csv << rows.headers
      csv << rows.find { |row| row["sure_entry_id"] == entry.id }.fields
    end
    Family::DataImporter.new(@target, files.fetch("all.ndjson")).import!
    restored = @target.entries.find_by!(name: "Synthetic backup merchant")
    assert_includes restored.transaction.extra.dig("csv", "sure_entry_ids"), entry.id

    repeated = TransactionImport.create!(family: @target, account: restored.account, raw_file_str: native_csv,
      date_col_label: "date", date_format: "%Y-%m-%d", timestamp_col_label: "transacted_at",
      amount_col_label: "amount", name_col_label: "name", currency_col_label: "currency",
      signage_convention: "inflows_negative")
    repeated.generate_rows_from_csv
    assert_no_difference "Entry.count" do
      repeated.publish
    end
    assert_equal "complete", repeated.status, repeated.error
    assert_equal restored.id, repeated.entries.first.id
  end

  test "a split child keeps its own Sure export ID after NDJSON restore" do
    child = @entry.split!([ { name: "Split ID Child", amount: @entry.amount / 2 },
                            { name: "Other split", amount: @entry.amount / 2 } ]).first
    files = exported_files
    rows = CSV.parse(files.fetch("transactions.csv"), headers: true)
    child_csv = CSV.generate do |csv|
      csv << rows.headers
      csv << rows.find { |row| row["sure_entry_id"] == child.id }.fields
    end

    Family::DataImporter.new(@target, files.fetch("all.ndjson")).import!
    restored = @target.entries.find_by!(name: "Split ID Child")
    repeated = TransactionImport.create!(family: @target, account: restored.account, raw_file_str: child_csv,
      date_col_label: "date", date_format: "%Y-%m-%d", timestamp_col_label: "transacted_at",
      amount_col_label: "amount", name_col_label: "name", currency_col_label: "currency",
      signage_convention: "inflows_negative")
    repeated.generate_rows_from_csv
    assert_no_difference "Entry.count" do
      repeated.publish
    end
    assert_equal "complete", repeated.status, repeated.error
    assert_equal restored.id, repeated.entries.first.id
  end

  test "NDJSON restores a split parent's shared foreign ID without claiming a child" do
    foreign_id = SecureRandom.uuid
    csv = "Date,Amount,Name,Occurred,sure_entry_id\n2026-09-19,0,Synthetic split export,2026-09-19T10:45Z,#{foreign_id}\n"
    source_import = TransactionImport.create!(family: @source, account: @entry.account, raw_file_str: csv,
      date_col_label: "Date", date_format: "%Y-%m-%d", timestamp_col_label: "Occurred",
      amount_col_label: "Amount", name_col_label: "Name", signage_convention: "inflows_negative")
    source_import.generate_rows_from_csv
    source_import.publish
    assert_equal "complete", source_import.status, source_import.error
    source_import.entries.first.split!([ { name: "First", amount: 0 }, { name: "Second", amount: 0 } ])

    Family::DataImporter.new(@target, exported_files.fetch("all.ndjson")).import!
    restored = @target.entries.find_by!(name: "Synthetic split export")
    repeated = TransactionImport.create!(family: @target, account: restored.account, raw_file_str: csv,
      date_col_label: "Date", date_format: "%Y-%m-%d", timestamp_col_label: "Occurred",
      amount_col_label: "Amount", name_col_label: "Name", signage_convention: "inflows_negative")
    repeated.generate_rows_from_csv
    assert_no_difference "Entry.count" do
      repeated.publish
    end
    assert_equal "complete", repeated.status, repeated.error
    assert_equal restored.id, repeated.entries.first.id
  end

  test "NDJSON restores a split child's own CSV provenance independently of its parent" do
    parent = @entry.account.entries.create!(date: "2026-09-17", amount: 0, currency: "USD",
      name: "Synthetic split parent", entryable: Transaction.new)
    child = parent.split!([ { name: "Synthetic split child", amount: 0 } ]).first
    csv = "Date,Amount,Name,Occurred\n2026-09-17,0,Synthetic split child,2026-09-17T14:48:50Z\n"
    imported = TransactionImport.create!(family: @source, account: @entry.account, raw_file_str: csv,
      date_col_label: "Date", date_format: "%Y-%m-%d", timestamp_col_label: "Occurred",
      amount_col_label: "Amount", name_col_label: "Name", signage_convention: "inflows_negative")
    imported.generate_rows_from_csv
    imported.publish
    assert_equal "complete", imported.status, imported.error
    assert_equal "2026-09-17T14:48:50.000000Z", child.reload.transaction.extra.dig("csv", "transacted_at")
    parent.update!(transacted_at: Time.utc(2026, 9, 17, 18))

    Family::DataImporter.new(@target, exported_files.fetch("all.ndjson")).import!
    restored = @target.entries.find_by!(name: "Synthetic split child")
    assert_equal parent.transacted_at, restored.transacted_at
    assert_equal child.transaction.extra.dig("csv", "transacted_at"), restored.transaction.extra.dig("csv", "transacted_at")

    reimport = TransactionImport.create!(family: @target, account: restored.account, raw_file_str: csv,
      date_col_label: "Date", date_format: "%Y-%m-%d", timestamp_col_label: "Occurred",
      amount_col_label: "Amount", name_col_label: "Name", signage_convention: "inflows_negative")
    reimport.generate_rows_from_csv
    assert_no_difference "Entry.count" do
      reimport.publish
    end
    assert_equal "complete", reimport.status, reimport.error
    assert_equal restored.id, reimport.entries.first.id
  end

  test "old exports without occurrence timestamps remain supported" do
    lines = exported_files.fetch("all.ndjson").lines.map do |line|
      record = JSON.parse(line)
      record["data"].except!("transacted_at", "csv_transacted_at", "csv_source_date", "csv_sure_entry_ids", "transacted_at_locked")
      record.to_json
    end
    Family::DataImporter.new(@target, lines.join("\n")).import!
    assert_nil @target.entries.find_by!(name: @entry.name).transacted_at
  end

  test "session restores reject malformed timestamp metadata without partial writes" do
    invalid_values = {
      "entry_id" => [ 123, {}, false, " " ],
      "csv_sure_entry_ids" => [ [ 123 ], [ nil ], [ "" ], { "id" => @entry.id }, @entry.id ],
      "transacted_at" => [ "2026-02-30T12:00:00Z", 123 ],
      "csv_transacted_at" => [ "2026-09-17T12:00", {} ],
      "csv_source_date" => [ "2026-02-30", 123 ]
    }
    records = exported_files.fetch("all.ndjson").lines.map { |line| JSON.parse(line) }
    session = @target.import_sessions.create!(expected_chunks: 1)

    invalid_values.each do |field, values|
      values.each do |value|
        malformed = records.deep_dup
        malformed.find { |record| record["type"] == "Transaction" }["data"][field] = value
        assert_no_difference [ "Account.count", "Entry.count", "Transaction.count", "ImportSourceMapping.count" ] do
          error = assert_raises(Family::DataImporter::InvalidRecordError) do
            Family::DataImporter.new(@target, malformed.map(&:to_json).join("\n"), import_session: session).import!
          end
          assert_equal "invalid_import_record", error.code
          assert_equal field, error.details[:field]
          assert_equal value, error.details[:value]
        end
      end
    end
  end

  test "legacy restores skip transactions with invalid identities instead of discarding identity metadata" do
    records = exported_files.fetch("all.ndjson").lines.map { |line| JSON.parse(line) }
    record = records.find { |item| item["type"] == "Transaction" && item["data"]["name"] == @entry.name }
    record["data"]["csv_sure_entry_ids"] = [ SecureRandom.uuid, 123 ]

    result = Family::DataImporter.new(@target, records.map(&:to_json).join("\n")).import!

    assert_nil @target.entries.find_by(name: @entry.name)
    assert_equal 1, result[:summary]["transactions"]["skipped"]
  end

  test "invalid split metadata skips the whole legacy transaction before creating its parent" do
    @entry.split!([ { name: "Invalid child", amount: @entry.amount / 2 },
                    { name: "Valid child", amount: @entry.amount / 2 } ])
    records = exported_files.fetch("all.ndjson").lines.map { |line| JSON.parse(line) }
    record = records.find { |item| item["type"] == "Transaction" && item["data"]["name"] == @entry.name }
    record["data"]["split_lines"].first["entry_id"] = 123

    result = Family::DataImporter.new(@target, records.map(&:to_json).join("\n")).import!

    assert_nil @target.entries.find_by(name: @entry.name)
    assert_nil @target.entries.find_by(name: "Invalid child")
    assert_nil @target.entries.find_by(name: "Valid child")
    assert_equal 1, result[:summary]["transactions"]["skipped"]
  end

  test "invalid split metadata rolls back session restores" do
    @entry.split!([ { name: "Invalid child", amount: @entry.amount } ])
    records = exported_files.fetch("all.ndjson").lines.map { |line| JSON.parse(line) }
    record = records.find { |item| item["type"] == "Transaction" && item["data"]["name"] == @entry.name }
    record["data"]["split_lines"].first["csv_source_date"] = "2026-02-30"
    session = @target.import_sessions.create!(expected_chunks: 1)

    assert_no_difference [ "Account.count", "Entry.count", "Transaction.count", "ImportSourceMapping.count" ] do
      error = assert_raises(Family::DataImporter::InvalidRecordError) do
        Family::DataImporter.new(@target, records.map(&:to_json).join("\n"), import_session: session).import!
      end
      assert_equal "csv_source_date", error.details[:field]
    end
  end

  test "backup identities normalize uppercase UUIDs and permit absent metadata" do
    records = exported_files.fetch("all.ndjson").lines.map { |line| JSON.parse(line) }
    record = records.find { |item| item["type"] == "Transaction" && item["data"]["name"] == @entry.name }
    record["data"]["entry_id"] = @entry.id.upcase
    record["data"]["csv_sure_entry_ids"] = [ @entry.id.upcase, @entry.id ]
    record["data"]["csv_transacted_at"] = nil
    record["data"]["csv_source_date"] = ""

    Family::DataImporter.new(@target, records.map(&:to_json).join("\n")).import!

    restored = @target.entries.find_by!(name: @entry.name)
    assert_equal [ @entry.id ], restored.transaction.extra.dig("csv", "sure_entry_ids")
    assert_equal @timestamp, restored.transacted_at
  end

  test "legacy opaque parent and child identities survive restore export and session restore" do
    @entry.split!([ { name: "Opaque child", amount: @entry.amount } ])
    records = exported_files.fetch("all.ndjson").lines.map { |line| JSON.parse(line) }
    record = records.find { |item| item["type"] == "Transaction" && item["data"]["name"] == @entry.name }
    record["data"]["entry_id"] = "OLD-ENTRY"
    record["data"]["split_lines"].first["entry_id"] = "OLD-CHILD"
    Family::DataImporter.new(@target, records.map(&:to_json).join("\n")).import!

    final_family = Family.create!(name: "Second restore", currency: "USD", locale: "en")
    session = final_family.import_sessions.create!(expected_chunks: 1)
    Family::DataImporter.new(final_family, exported_files(@target).fetch("all.ndjson"), import_session: session).import!

    parent = final_family.entries.find_by!(name: @entry.name)
    child = final_family.entries.find_by!(name: "Opaque child")
    assert_includes parent.transaction.extra.dig("csv", "sure_entry_ids"), "old-entry"
    assert_includes child.transaction.extra.dig("csv", "sure_entry_ids"), "old-child"
    assert_equal @timestamp, parent.transacted_at
  end

  test "trade CSV and NDJSON preserve timestamps after transaction conversion" do
    security = Security.create!(ticker: "TIMESTAMPTEST", name: "Synthetic security")
    account = @source.accounts.create!(name: "Timestamp investments", balance: 0, currency: "USD", accountable: Investment.new)
    account.entries.create!(date: "2026-09-18", transacted_at: @timestamp, amount: 10, currency: "USD", name: "Buy",
      entryable: Trade.new(security: security, qty: 1, price: 10, currency: "USD"))
    files = exported_files
    csv_rows = CSV.parse(files.fetch("trades.csv"), headers: true)
    row = csv_rows.find { |item| item["ticker"] == security.ticker }
    assert_equal @timestamp.iso8601(6), row["transacted_at"]

    restored_account = @target.accounts.create!(name: "Restored investments", balance: 0, currency: "USD", accountable: Investment.new)
    csv = CSV.generate { |output| output << csv_rows.headers; output << row.fields }
    import = TradeImport.create!(family: @target, account: restored_account, raw_file_str: csv,
      date_col_label: "date", date_format: "%Y-%m-%d", qty_col_label: "quantity", ticker_col_label: "ticker",
      price_col_label: "price", currency_col_label: "currency", timestamp_col_label: "transacted_at")
    Security::Resolver.any_instance.stubs(:resolve).returns(security)
    import.generate_rows_from_csv
    import.publish
    assert_equal "complete", import.status, import.error
    assert_equal @timestamp, import.entries.first.transacted_at

    Family::DataImporter.new(@target, files.fetch("all.ndjson")).import!
    restored = @target.accounts.find_by!(name: account.name)
    assert_equal @timestamp, restored.entries.trades.first.transacted_at
  end

  private
    def exported_files(family = @source)
      files = {}
      Zip::InputStream.open(Family::DataExporter.new(family).generate_export) do |zip|
        while (entry = zip.get_next_entry)
          files[entry.name] = zip.read
        end
      end
      files
    end
end
