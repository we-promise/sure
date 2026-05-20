require "test_helper"

class SureImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @import = @family.imports.create!(type: "SureImport")
  end

  test "dry_run reflects attached ndjson content" do
    ndjson = [
      { type: "Account", data: { id: "uuid-1", name: "Test", balance: "1000", currency: "USD", accountable_type: "Depository" } },
      { type: "Transaction", data: { id: "uuid-2" } }
    ].map(&:to_json).join("\n")

    attach_ndjson(ndjson)

    dry_run = @import.dry_run

    assert_equal 1, dry_run[:accounts]
    assert_equal 1, dry_run[:transactions]
  end

  test "publishable? is false when attached file has no supported records" do
    ndjson = { type: "UnknownType", data: {} }.to_json
    attach_ndjson(ndjson)

    assert @import.uploaded?
    assert_not @import.publishable?
  end

  test "column_keys required_column_keys and mapping_steps are empty" do
    assert_equal [], @import.column_keys
    assert_equal [], @import.required_column_keys
    assert_equal [], @import.mapping_steps
  end

  test "max_row_count is higher than standard imports" do
    assert_equal 100_000, SureImport.max_row_count
    assert_equal 100_000, @import.max_row_count
  end

  test "dry_run totals can be derived from existing line type counts" do
    counts = {
      "Account" => 2,
      "Transaction" => 3,
      "UnknownType" => 4
    }

    dry_run = SureImport.dry_run_totals_from_line_type_counts(counts)

    assert_equal 2, dry_run[:accounts]
    assert_equal 3, dry_run[:transactions]
    assert_equal 0, dry_run[:categories]
    assert_not dry_run.key?(:unknown_type)
  end

  test "ndjson line type counts ignore records without data" do
    ndjson = [
      { type: "Account", data: { id: "uuid-1" } },
      { type: "Transaction" },
      { data: { id: "uuid-2" } }
    ].map(&:to_json).join("\n")

    counts = SureImport.ndjson_line_type_counts(ndjson)

    assert_equal({ "Account" => 1 }, counts)
  end

  test "csv_template returns nil" do
    assert_nil @import.csv_template
  end

  test "uploaded? returns false without ndjson attachment" do
    assert_not @import.uploaded?
  end

  test "uploaded? returns true with valid ndjson attachment" do
    attach_ndjson(build_ndjson([
      { type: "Account", data: { id: "uuid-1", name: "Test", balance: "1000", currency: "USD", accountable_type: "Depository" } }
    ]))

    assert @import.uploaded?
  end

  test "uploaded? returns false with invalid ndjson attachment" do
    attach_ndjson("not valid json")

    assert_not @import.uploaded?
  end

  test "configured? and cleaned? follow uploaded?" do
    attach_ndjson(build_ndjson([
      { type: "Account", data: { id: "uuid-1", name: "Test", balance: "1000", currency: "USD", accountable_type: "Depository" } }
    ]))

    assert @import.configured?
    assert @import.cleaned?
  end

  test "publishable? returns true when uploaded and valid" do
    attach_ndjson(build_ndjson([
      { type: "Account", data: { id: "uuid-1", name: "Test", balance: "1000", currency: "USD", accountable_type: "Depository" } }
    ]))

    assert @import.publishable?
  end

  test "status predicates honor validation stats" do
    attach_ndjson(build_ndjson([
      { type: "Account", data: { id: "uuid-1", name: "Test", balance: "1000", currency: "USD", accountable_type: "Depository" } }
    ]))

    assert @import.cleaned_from_validation_stats?(invalid_rows_count: 0)
    assert @import.publishable_from_validation_stats?(invalid_rows_count: 0)
    assert_not @import.cleaned_from_validation_stats?(invalid_rows_count: 1)
    assert_not @import.publishable_from_validation_stats?(invalid_rows_count: 1)
  end

  test "dry_run returns counts by type" do
    attach_ndjson(build_ndjson([
      { type: "Account", data: { id: "uuid-1" } },
      { type: "Account", data: { id: "uuid-2" } },
      { type: "Category", data: { id: "uuid-3" } },
      { type: "Transaction", data: { id: "uuid-4" } },
      { type: "Transaction", data: { id: "uuid-5" } },
      { type: "Transaction", data: { id: "uuid-6" } }
    ]))

    dry_run = @import.dry_run

    assert_equal 2, dry_run[:accounts]
    assert_equal 1, dry_run[:categories]
    assert_equal 3, dry_run[:transactions]
    assert_equal 0, dry_run[:tags]
  end

  test "cached ndjson content is refreshed when attachment is replaced" do
    attach_ndjson(build_ndjson([
      { type: "Account", data: { id: "uuid-1" } }
    ]))
    assert_equal 1, @import.dry_run[:accounts]

    attach_ndjson(build_ndjson([
      { type: "Transaction", data: { id: "uuid-2" } }
    ]))

    dry_run = @import.dry_run
    assert_equal 0, dry_run[:accounts]
    assert_equal 1, dry_run[:transactions]
    assert_equal 1, @import.rows_count
  end

  test "sync_ndjson_rows_count! sets total row count" do
    attach_ndjson(build_ndjson([
      { type: "Account", data: { id: "uuid-1" } },
      { type: "Category", data: { id: "uuid-2" } },
      { type: "Transaction", data: { id: "uuid-3" } }
    ]))

    @import.sync_ndjson_rows_count!

    assert_equal 3, @import.rows_count
  end

  test "sync_ndjson_rows_count! persists expected record counts" do
    attach_ndjson(build_ndjson([
      { type: "Account", data: { id: "account-1" } },
      { type: "Balance", data: { id: "balance-1" } },
      { type: "Transaction", data: { id: "transaction-1" } },
      { type: "UnknownType", data: { id: "unknown-1" } }
    ]))

    @import.reload

    assert_equal 4, @import.rows_count
    assert_equal 1, @import.expected_record_counts["accounts"]
    assert_equal 1, @import.expected_record_counts["balances"]
    assert_equal 1, @import.expected_record_counts["transactions"]
    assert_not @import.expected_record_counts.key?("unknown_type")
    assert_equal({}, @import.readback_verification)
  end

  test "import resyncs expected counts from current attachment" do
    attach_ndjson(build_ndjson([
      { type: "Account", data: { id: "stale-account" } }
    ]))
    @import.ndjson_file.attach(
      io: StringIO.new(build_ndjson([
        { type: "Category", data: {
          id: "current-category",
          name: "Current Category",
          color: "#407706",
          classification: "expense",
          lucide_icon: "shapes"
        } }
      ])),
      filename: "current.ndjson",
      content_type: "application/x-ndjson"
    )

    @import.import!
    @import.reload

    assert_equal 1, @import.rows_count
    assert_equal 0, @import.expected_record_counts["accounts"]
    assert_equal 1, @import.expected_record_counts["categories"]
    assert_equal 1, @import.readback_verification.dig("expected_record_counts", "categories")
    assert_equal "matched", @import.readback_verification["status"]
  end

  test "publishes import successfully" do
    attach_ndjson(build_ndjson([
      { type: "Account", data: {
        id: "uuid-1",
        name: "Import Test Account",
        balance: "1000.00",
        currency: "USD",
        accountable_type: "Depository",
        accountable: { subtype: "checking" }
      } }
    ]))

    initial_account_count = @family.accounts.count

    @import.publish

    assert_equal "complete", @import.status
    assert_equal initial_account_count + 1, @family.accounts.count

    account = @family.accounts.find_by(name: "Import Test Account")
    assert_not_nil account
    assert_equal 1000.0, account.balance.to_f
    assert_equal "USD", account.currency
    assert_equal "Depository", account.accountable_type
  end

  test "publish records matched readback verification from family-scoped deltas" do
    other_family = Family.create!(name: "Other Family", currency: "USD", locale: "en", date_format: "%m-%d-%Y")
    other_family.accounts.create!(
      name: "Other Checking",
      balance: 100,
      currency: "USD",
      accountable: Depository.new
    )

    attach_ndjson(importable_history_ndjson)

    @import.publish
    @import.reload

    verification = @import.readback_verification

    assert_equal "complete", @import.status
    assert_equal "matched", verification["status"]
    assert_equal 1, verification.dig("expected_record_counts", "accounts")
    assert_equal 1, verification.dig("expected_record_counts", "categories")
    assert_equal 1, verification.dig("expected_record_counts", "tags")
    assert_equal 1, verification.dig("expected_record_counts", "merchants")
    assert_equal 1, verification.dig("expected_record_counts", "transactions")
    assert_equal 1, verification.dig("expected_record_counts", "valuations")
    assert_equal 1, verification.dig("actual_delta_counts", "accounts")
    assert_equal 1, verification.dig("actual_delta_counts", "categories")
    assert_equal 1, verification.dig("actual_delta_counts", "tags")
    assert_equal 1, verification.dig("actual_delta_counts", "merchants")
    assert_equal 1, verification.dig("actual_delta_counts", "transactions")
    assert_equal 1, verification.dig("actual_delta_counts", "valuations")
    assert_equal 0, verification.dig("checked_counts", "balances")
    assert_empty verification["mismatches"]
    assert_equal 1, other_family.accounts.count
  end

  test "publish verifies expected zero record types against unexpected readback deltas" do
    attach_ndjson(build_ndjson([
      { type: "Account", data: {
        id: "account-1",
        name: "Implicit Opening Anchor",
        balance: "100.00",
        currency: "USD",
        accountable_type: "Depository",
        accountable: { subtype: "checking" }
      } }
    ]))

    @import.publish
    @import.reload

    verification = @import.readback_verification

    assert_equal "complete", @import.status
    assert_equal "mismatch", verification["status"]
    assert_equal 0, verification.dig("expected_record_counts", "valuations")
    assert_equal 0, verification.dig("checked_counts", "valuations")
    assert_equal 1, verification.dig("actual_delta_counts", "valuations")
    assert_equal({ "expected" => 0, "actual" => 1 }, verification.dig("mismatches", "valuations"))
  end

  test "publish records mismatch when expected rows are skipped by readback" do
    attach_ndjson(build_ndjson([
      { type: "Transaction", data: {
        id: "transaction-1",
        account_id: "missing-account",
        date: "2024-01-15",
        amount: "12.34",
        name: "Skipped transaction",
        currency: "USD"
      } }
    ]))

    @import.publish
    @import.reload

    assert_equal "complete", @import.status
    assert_equal "mismatch", @import.readback_verification["status"]
    assert_equal({ "expected" => 1, "actual" => 0 }, @import.readback_verification.dig("mismatches", "transactions"))
  end

  test "failed publish records failed verification without partial mutation" do
    attach_ndjson(build_ndjson([
      { type: "Account", data: {
        id: "account-1",
        name: "Rollback Account",
        balance: "100.00",
        currency: "USD",
        accountable_type: "Depository"
      } },
      { type: "Transaction", data: {
        id: "transaction-1",
        account_id: "account-1",
        date: "not-a-date",
        amount: "12.34",
        name: "Bad date",
        currency: "USD"
      } }
    ]))

    initial_account_count = @family.accounts.count
    initial_transaction_count = @family.entries.where(entryable_type: "Transaction").count

    @import.publish
    @import.reload

    assert_equal "failed", @import.status
    assert_equal initial_account_count, @family.accounts.count
    assert_equal initial_transaction_count, @family.entries.where(entryable_type: "Transaction").count
    assert_equal "failed", @import.readback_verification["status"]
    assert_equal 0, @import.readback_verification.dig("actual_delta_counts", "accounts")
    assert_equal 0, @import.readback_verification.dig("actual_delta_counts", "transactions")
  end

  test "failed publish keeps original error when failed verification cannot be recorded" do
    before_counts = @import.send(:readback_count_snapshot)
    original_error = StandardError.new("original import failure")
    logged_messages = []

    Rails.logger.stubs(:warn).with do |message|
      logged_messages << message unless logged_messages.include?(message)
      true
    end
    @import.stubs(:update_columns).raises(StandardError, "verification write failed")

    @import.send(:record_failed_readback_verification!, before_counts:, error: original_error)

    assert_match(/Failed to record Sure import readback verification/, logged_messages.first)
    assert_match(/verification write failed/, logged_messages.first)
  end

  test "revert marks Sure readback verification as reverted" do
    attach_ndjson(importable_history_ndjson)

    @import.publish
    assert_equal "matched", @import.reload.verification_status

    @import.revert

    assert_equal "pending", @import.status
    assert_equal "reverted", @import.verification_status
  end

  test "revert failure leaves existing Sure readback verification untouched" do
    attach_ndjson(importable_history_ndjson)

    @import.publish
    verification = @import.reload.readback_verification

    @import.stub(:entries, -> { raise StandardError, "revert failed before pending" }) do
      @import.revert
    end

    assert_equal "revert_failed", @import.status
    assert_equal verification, @import.readback_verification
    assert_equal "matched", @import.verification_status
  end

  test "import tracks created accounts for revert" do
    attach_ndjson(build_ndjson([
      { type: "Account", data: {
        id: "uuid-1",
        name: "Revertable Account",
        balance: "500.00",
        currency: "USD",
        accountable_type: "Depository"
      } }
    ]))

    @import.publish

    assert_equal 1, @import.accounts.count
    assert_equal "Revertable Account", @import.accounts.first.name
  end

  test "publishes later enqueues job" do
    attach_ndjson(build_ndjson([
      { type: "Account", data: {
        id: "uuid-1",
        name: "Async Account",
        balance: "100",
        currency: "USD",
        accountable_type: "Depository"
      } }
    ]))

    assert_enqueued_with job: ImportJob, args: [ @import ] do
      @import.publish_later
    end

    assert_equal "importing", @import.status
  end

  private

    def attach_ndjson(ndjson)
      @import.ndjson_file.attach(
        io: StringIO.new(ndjson),
        filename: "all.ndjson",
        content_type: "application/x-ndjson"
      )
      @import.sync_ndjson_rows_count!
    end

    def build_ndjson(records)
      records.map(&:to_json).join("\n")
    end

    def importable_history_ndjson
      build_ndjson([
        { type: "Account", data: {
          id: "account-1",
          name: "Verified Checking",
          balance: "1000.00",
          currency: "USD",
          accountable_type: "Depository",
          accountable: { subtype: "checking" }
        } },
        { type: "Valuation", data: {
          id: "valuation-1",
          account_id: "account-1",
          date: "2024-01-14",
          amount: "1000.00",
          currency: "USD",
          kind: "opening_anchor"
        } },
        { type: "Category", data: {
          id: "category-1",
          name: "Verified Category",
          color: "#407706",
          classification: "expense",
          lucide_icon: "shapes"
        } },
        { type: "Tag", data: {
          id: "tag-1",
          name: "Verified Tag",
          color: "#407706"
        } },
        { type: "Merchant", data: {
          id: "merchant-1",
          name: "Verified Merchant",
          color: "#407706"
        } },
        { type: "Transaction", data: {
          id: "transaction-1",
          account_id: "account-1",
          category_id: "category-1",
          merchant_id: "merchant-1",
          tag_ids: [ "tag-1" ],
          date: "2024-01-15",
          amount: "12.34",
          name: "Verified transaction",
          currency: "USD"
        } }
      ])
    end
end
