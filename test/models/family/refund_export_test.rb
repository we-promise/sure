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
    Transaction.any_instance.expects(:update!).never

    restore_export

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
    session = @target.import_sessions.create!

    assert_raises(Family::DataImporter::MissingReferenceError) do
      Family::DataImporter.new(@target, records.map(&:to_json).join("\n"), import_session: session).import!
    end
    assert_empty @target.transactions
  end

  private
    def export_records
      Zip::File.open_buffer(Family::DataExporter.new(@family).generate_export) do |zip|
        zip.read("all.ndjson").lines.map { |line| JSON.parse(line) }
      end
    end

    def restore_export
      # Import must not rely on UUID or chronological ordering.
      transactions, others = export_records.partition { |record| record["type"] == "Transaction" }
      transactions.sort_by! { |record| record["data"]["amount"].to_d }
      Family::DataImporter.new(@target, (others + transactions).map(&:to_json).join("\n")).import!
    end
end
