require "test_helper"

class Family::RefundExportTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Checking", currency: "USD", balance: 1000, accountable: Depository.new)
    @purchase = create_transaction(account: @account, name: "Shirts", amount: 1000)
    @target = Family.create!(name: "Restored", currency: "USD")
  end

  test "restores purchase links regardless of transaction order" do
    refund = create_transaction(account: @account, name: "Refund", amount: -800)
    refund.transaction.mark_as_refund!(purchase: @purchase.transaction)
    create_transaction(account: @account, name: "Unlinked refund", amount: -50, kind: "refund")
    restore_export

    assert_nil @target.transactions.joins(:entry).find_by!(entries: { name: "Unlinked refund" }).refund_of
    restored = @target.transactions.joins(:entry).find_by!(entries: { name: "Shirts" })
    assert_equal 1, restored.purchase_refunds.count
    assert_equal Money.new(200, "USD"), restored.purchase_net_cost_money
    assert_not_equal @purchase.transaction.id, restored.id
  end

  test "restores links from split refunds to split purchases" do
    purchases = @purchase.split!([
      { name: "Shirts", amount: 600 }, { name: "Shoes", amount: 400 }
    ])
    credit = create_transaction(account: @account, name: "Combined refund", amount: -800)
    refunds = credit.split!([
      { name: "Shirts refund", amount: -500 }, { name: "Shoes refund", amount: -300 }
    ])
    refunds.zip(purchases).each do |refund, purchase|
      refund.transaction.reload.mark_as_refund!(purchase: purchase.transaction.reload)
    end
    restore_export

    restored_refunds = @target.transactions.where(kind: "refund")
    assert_equal 2, restored_refunds.count
    restored_refunds.each do |refund|
      assert_not_nil refund.refund_of
      assert_equal Money.new(100, "USD"), refund.refund_of.purchase_net_cost_money
    end
  end

  test "restores multiple refunds without loading each transaction separately" do
    5.times do |index|
      refund = create_transaction(account: @account, name: "Refund #{index}", amount: -100)
      refund.transaction.mark_as_refund!(purchase: @purchase.transaction)
    end

    queries = capture_sql_queries { restore_export }
    transaction_loads = queries.grep(/SELECT "transactions"\.\* FROM "transactions"/)
    # Includes the export's transaction loads as well as restoration.
    assert_operator transaction_loads.size, :<=, 4, transaction_loads.join("\n")

    restored = @target.transactions.joins(:entry).find_by!(entries: { name: "Shirts" })
    assert_equal 5, restored.purchase_refunds.count
    assert_equal Money.new(500, "USD"), restored.purchase_net_cost_money
  end

  test "unlinked archive transactions do not issue refund link updates" do
    create_transaction(account: @account, name: "Unlinked refund", amount: -50, kind: "refund")

    queries = capture_sql_queries { restore_export }

    assert_empty queries.grep(/UPDATE "transactions".*"refund_of_id"/)
    assert_equal 2, @target.transactions.count
    assert_nil @target.transactions.refund.sole.refund_of_id
  end

  test "replaying an archive can explicitly clear an existing refund link" do
    refund = create_transaction(account: @account, name: "Refund", amount: -800)
    refund.transaction.mark_as_refund!(purchase: @purchase.transaction)
    session = @target.import_sessions.create!
    records = export_records
    Family::DataImporter.new(@target, records.map(&:to_json).join("\n"), import_session: session).import!
    restored = @target.transactions.refund.sole
    assert_not_nil restored.refund_of_id

    records.find { |record| record.dig("data", "id") == refund.transaction.id }["data"]["refund_of_id"] = nil
    Family::DataImporter.new(@target, records.map(&:to_json).join("\n"), import_session: session).import!

    assert_nil restored.reload.refund_of_id
    assert restored.refund?
    assert_equal 2, @target.transactions.count
  end

  test "a card-payment refund restores its previous kind after an archive round trip" do
    credit = create_transaction(account: @account, name: "Card payment return", amount: -100, kind: "cc_payment")
    credit.transaction.mark_as_refund!

    restore_export

    restored = @target.transactions.refund.sole
    restored.clear_refund!
    assert restored.reload.cc_payment?, "the archived refund metadata must restore previous_kind"
  end

  test "restored refunds keep their explicit classification lock" do
    refund = create_transaction(account: @account, name: "Refund", amount: -800)
    refund.transaction.mark_as_refund!
    restore_export

    restored = @target.transactions.refund.sole
    assert restored.locked?(:kind)
  end

  test "replaying an allocation for a refund skips it instead of failing the restore" do
    series = @family.recurring_transactions.create!(
      account: @account, name: "Salary", amount: -1000, currency: "USD",
      expected_day_of_month: Date.current.day, last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date, status: "active",
      manual: true, bill_type: "income"
    )
    occurrence = series.recurring_occurrences.order(:due_on).last ||
      series.recurring_occurrences.create!(
        family: @family, original_due_on: Date.current, due_on: Date.current,
        currency: "USD", expected_amount: 1000, status: "scheduled"
      )
    entry = create_transaction(account: @account, name: "Salary", amount: -1000)
    RecurringTransaction::Allocator.new(occurrence).allocate!(entry: entry)
    # Bypass the callback to model an allocation exported by an older build.
    entry.transaction.update_column(:kind, "refund")

    session = @target.import_sessions.create!(expected_chunks: 1)
    session.attach_chunk!(
      sequence: 1,
      content: export_records.map(&:to_json).join("\n"),
      filename: "all.ndjson",
      content_type: "application/x-ndjson"
    )
    session.publish

    assert session.reload.complete?, session.error_details.inspect
    assert @target.transactions.refund.exists?
    assert_equal 0, RecurringAllocation.where(
      recurring_occurrence_id: @target.recurring_occurrences.select(:id)
    ).count
    restored_series = @target.recurring_transactions.find_by!(name: series.name)
    assert restored_series.recurring_occurrences.find_by!(due_on: occurrence.due_on).scheduled?,
      "removing the only refund payment must reopen the automatically paid occurrence"
  end

  test "defers an allocation whose transaction is in a later session chunk" do
    series = @family.recurring_transactions.create!(
      account: @account, name: "Chunked salary #{SecureRandom.hex(4)}", amount: -1000, currency: "USD",
      expected_day_of_month: Date.current.day, last_occurrence_date: Date.current,
      next_expected_date: 1.month.from_now.to_date, status: "active", manual: true, bill_type: "income"
    )
    occurrence = series.recurring_occurrences.order(:due_on).last ||
      series.recurring_occurrences.create!(family: @family, original_due_on: Date.current,
        due_on: Date.current, currency: "USD", expected_amount: 1000, status: "scheduled")
    entry = create_transaction(account: @account, name: "Chunked salary", amount: -1000)
    RecurringTransaction::Allocator.new(occurrence).allocate!(entry: entry)

    records = export_records
    transaction_record = records.find { |record| record.dig("data", "id") == entry.entryable_id }
    records = records.reject { |record| record.equal?(transaction_record) }
    session = @target.import_sessions.create!(expected_chunks: 2)
    session.attach_chunk!(sequence: 1, content: records.map(&:to_json).join("\n"),
      filename: "entities.ndjson", content_type: "application/x-ndjson")
    session.attach_chunk!(sequence: 2, content: transaction_record.to_json,
      filename: "transaction.ndjson", content_type: "application/x-ndjson")

    session.publish

    assert session.reload.complete?, session.error_details.inspect
    restored = @target.recurring_transactions.find_by!(name: series.name)
    allocation = RecurringAllocation.joins(:recurring_occurrence)
      .where(recurring_occurrences: { recurring_transaction_id: restored.id }).sole
    assert_not_nil allocation.entry_id
    assert_equal "Chunked salary", allocation.entry.name
  end

  test "detaching a replayed link finds a split child through its source mapping" do
    target_account = @target.accounts.create!(name: "Restored checking", currency: "USD", balance: 0, accountable: Depository.new)
    purchase = create_transaction(account: target_account, name: "Split purchase", amount: 1000)
    refund = create_transaction(account: target_account, name: "Split refund", amount: -1000)
    refund.transaction.mark_as_refund!
    child = refund.split!([ { name: "Half", amount: -500 }, { name: "Half", amount: -500 } ]).first
    child.transaction.mark_as_refund!(purchase: purchase.transaction)

    session = @target.import_sessions.create!
    session.source_mappings.create!(
      family: @target, source_type: "Transaction", source_id: "child-source-id", target: child.transaction
    )

    assert_equal purchase.transaction, child.transaction.reload.refund_of
    importer = Family::DataImporter.new(@target, "", import_session: session)
    importer.send(:detach_replayed_refund_link, target_account,
      { "id" => "child-source-id", "refund_of_id" => nil })

    assert_nil child.transaction.reload.refund_of_id
  end

  test "replaying an unlink before a split does not leave a stale purchase link" do
    refund = create_transaction(account: @account, name: "Refund", amount: -800)
    refund.transaction.mark_as_refund!(purchase: @purchase.transaction)
    session = @target.import_sessions.create!
    Family::DataImporter.new(@target, export_records.map(&:to_json).join("\n"), import_session: session).import!

    refund.transaction.reload.clear_refund!
    @purchase.split!([ { name: "Shirts", amount: 600 }, { name: "Shoes", amount: 400 } ])

    records = export_records
    refund_record = records.find { |record| record.dig("data", "id") == refund.transaction.id }
    # Put the purchase and its split rows before the refund that unlinks it.
    records = records.reject { |record| record.equal?(refund_record) } << refund_record

    assert_nothing_raised do
      Family::DataImporter.new(@target, records.map(&:to_json).join("\n"), import_session: session).import!
    end

    restored_purchase = @target.entries.find_by!(name: "Shirts", parent_entry_id: nil)
    assert_equal 2, restored_purchase.child_entries.count
    restored_refund = @target.transactions.joins(:entry).find_by!(entries: { name: "Refund" })
    assert restored_refund.standard?
    assert_nil restored_refund.refund_of_id
  end

  test "replaying a standard transaction with an explicit null link does not fail validation" do
    refund = create_transaction(account: @account, name: "Refund", amount: -800)
    refund.transaction.mark_as_refund!(purchase: @purchase.transaction)
    session = @target.import_sessions.create!
    records = export_records
    Family::DataImporter.new(@target, records.map(&:to_json).join("\n"), import_session: session).import!
    restored = @target.transactions.refund.sole

    record = records.find { |row| row.dig("data", "id") == refund.transaction.id }
    record["data"]["kind"] = "standard"
    record["data"]["refund_of_id"] = nil

    assert_nothing_raised do
      Family::DataImporter.new(@target, records.map(&:to_json).join("\n"), import_session: session).import!
    end

    restored.reload
    assert restored.standard?
    assert_nil restored.refund_of_id
  end

  test "missing purchase links are optional outside strict session imports" do
    refund = create_transaction(account: @account, name: "Refund", amount: -800)
    refund.transaction.mark_as_refund!(purchase: @purchase.transaction)
    records = export_records.reject { |record| record.dig("data", "id") == @purchase.transaction.id }

    Family::DataImporter.new(@target, records.map(&:to_json).join("\n")).import!

    assert_nil @target.transactions.refund.sole.refund_of_id
  end

  test "strict session imports reject missing purchase links instead of silently losing them" do
    refund = create_transaction(account: @account, name: "Refund", amount: -800)
    refund.transaction.mark_as_refund!(purchase: @purchase.transaction)
    records = export_records.reject { |record| record.dig("data", "id") == @purchase.transaction.id }
    session = @target.import_sessions.create!(expected_chunks: 1)
    session.attach_chunk!(
      sequence: 1,
      content: records.map(&:to_json).join("\n"),
      filename: "all.ndjson",
      content_type: "application/x-ndjson"
    )

    session.publish

    assert session.reload.failed?
    assert_equal "missing_source_reference", session.error_details["code"]
    assert_nil @target.transactions.refund.sole.refund_of_id
  end

  private
    def export_records
      records = nil
      Zip::File.open_buffer(Family::DataExporter.new(@family).generate_export) do |zip|
        records = zip.read("all.ndjson").lines.map { |line| JSON.parse(line) }
      end
      records
    end

    def restore_export
      # Import must not rely on UUID or chronological ordering.
      transactions, others = export_records.partition { |record| record["type"] == "Transaction" }
      transactions.sort_by! { |record| record["data"]["amount"].to_d }
      Family::DataImporter.new(@target, (others + transactions).map(&:to_json).join("\n")).import!
    end
end
