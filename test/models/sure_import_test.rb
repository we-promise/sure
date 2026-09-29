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
    with_env_overrides(
      "SURE_IMPORT_MAX_ROWS" => nil,
      "SURE_IMPORT_MAX_NDJSON_SIZE_MB" => nil
    ) do
      assert_equal 100_000, SureImport.max_row_count
      assert_equal 100_000, @import.max_row_count
    end
  end

  test "max row count and ndjson size can be configured by environment" do
    with_env_overrides(
      "SURE_IMPORT_MAX_ROWS" => "150000",
      "SURE_IMPORT_MAX_NDJSON_SIZE_MB" => "64"
    ) do
      assert_equal 150_000, SureImport.max_row_count
      assert_equal 64.megabytes, SureImport.max_ndjson_size
    end
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

  test "import records mismatch when expected rows are skipped by readback" do
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

    initial_transaction_count = @family.entries.where(entryable_type: "Transaction").count

    @import.import!
    @import.reload

    assert_equal initial_transaction_count, @family.entries.where(entryable_type: "Transaction").count
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

  test "import tracks split parent entries for revert" do
    attach_ndjson(build_ndjson([
      { type: "Account", data: {
        id: "split-account",
        name: "Split Revert Account",
        balance: "500.00",
        currency: "USD",
        accountable_type: "Depository"
      } },
      { type: "Transaction", data: {
        id: "split-parent",
        account_id: "split-account",
        date: "2024-01-15",
        amount: "100.00",
        name: "Revertable split parent",
        currency: "USD",
        split_lines: [
          { id: "split-child-1", amount: "40.00", name: "Split child one" },
          { id: "split-child-2", amount: "60.00", name: "Split child two" }
        ]
      } }
    ]))

    @import.publish

    parent_entry = @family.entries.find_by!(name: "Revertable split parent")
    split_entry_ids = [ parent_entry.id, *parent_entry.child_entries.pluck(:id) ]

    assert parent_entry.split_parent?
    assert_equal 3, @import.entries.where(id: split_entry_ids).count

    assert_difference -> { Entry.where(id: split_entry_ids).count }, -3 do
      @import.revert
    end
    assert_equal "pending", @import.reload.status
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

  test "publish_later raises custom error when preflight passes but import is not publishable" do
    @import.stubs(:validate_sure_preflight!).returns(true)
    @import.stubs(:publishable?).returns(false)

    assert_no_enqueued_jobs do
      error = assert_raises SureImport::NotPublishableError do
        @import.publish_later
      end
      assert_equal "Import was uploaded but has no publishable records.", error.message
    end
    assert_equal "pending", @import.reload.status
  end

  test "publish_later restores previous status when enqueue fails" do
    attach_ndjson(build_ndjson([
      { type: "Account", data: {
        id: "account-1",
        name: "Queued Account",
        balance: "100",
        currency: "USD",
        accountable_type: "Depository"
      } }
    ]))
    ImportJob.stubs(:perform_later).raises(StandardError, "queue down")

    assert_no_enqueued_jobs do
      error = assert_raises StandardError do
        @import.publish_later
      end
      assert_equal "queue down", error.message
    end

    assert_equal "pending", @import.reload.status
  end

  test "preflight reports blocking errors before publish_later enqueues" do
    attach_ndjson(build_ndjson([
      { type: "Valuation", data: {
        account_id: "missing-account",
        date: "2024-01-01",
        amount: "100"
      } }
    ]))

    assert_no_enqueued_jobs do
      assert_raises SureImport::PreflightError do
        @import.publish_later
      end
    end

    assert_equal "failed", @import.reload.status
    assert_includes @import.error, "references missing account_id"
  end

  test "publish_later reports unsupported records through preflight before publishable check" do
    attach_ndjson(build_ndjson([
      { type: "MysteryType", data: { id: "mystery-1" } }
    ]))

    assert_no_enqueued_jobs do
      assert_raises SureImport::PreflightError do
        @import.publish_later
      end
    end

    assert_equal "failed", @import.reload.status
    assert_includes @import.error, "unsupported record type MysteryType"
  end

  test "publish preflight failure does not partially import records" do
    attach_ndjson(build_ndjson([
      { type: "Account", data: {
        id: "account-1",
        name: "Should Not Import",
        balance: "100",
        currency: "USD",
        accountable_type: "NotReal"
      } }
    ]))

    assert_no_difference -> { @family.accounts.where(name: "Should Not Import").count } do
      @import.publish
    end

    assert_equal "failed", @import.reload.status
    assert_includes @import.error, "invalid accountable_type"
  end

  test "preflight catches missing fields unsupported types duplicate valuations and references" do
    attach_ndjson(build_ndjson([
      { type: "RecurringTransaction", data: { id: "recurring-1" } },
      { type: "MysteryType", data: { id: "mystery-1" } },
      { type: "Account", data: {
        id: "account-1",
        name: "Bad Subtype",
        balance: "100",
        accountable_type: "Depository",
        accountable: { subtype: "not-a-subtype" }
      } },
      { type: "Valuation", data: { account_id: "account-1", date: "2024-01-01", amount: "100" } },
      { type: "Valuation", data: { account_id: "account-1", date: "2024-01-01", amount: "101" } },
      { type: "Transaction", data: {
        id: "transaction-1",
        account_id: "missing-account",
        date: "2024-01-02",
        amount: "-5",
        tag_ids: [ "missing-tag" ]
      } }
    ]))

    result = @import.sure_preflight
    codes = result.errors.map { |error| error[:code] }

    assert_not result.valid?
    assert_includes codes, "missing_required_fields"
    assert_includes codes, "unsupported_record_type"
    assert_includes codes, "invalid_accountable_subtype"
    assert_includes codes, "duplicate_valuation"
    assert_includes codes, "missing_reference"
  end

  test "preflight allows null rule names and treats orphaned rejected transfers as warnings" do
    attach_ndjson(build_ndjson([
      { type: "Rule", data: { id: "rule-1", name: nil, resource_type: "transaction" } },
      { type: "RejectedTransfer", data: {
        id: "rejected-1",
        inflow_transaction_id: "missing-inflow",
        outflow_transaction_id: "missing-outflow"
      } }
    ]))

    result = @import.sure_preflight

    assert result.valid?, result.error_message
    assert_empty result.errors
    assert_includes result.warnings.map { |warning| warning[:code] }, "skipped_missing_reference"
  end

  test "preflight localizes missing reference messages in German" do
    attach_ndjson(build_ndjson([
      { type: "Transaction", data: {
        id: "transaction-1",
        account_id: "missing-account",
        date: "2026-01-02",
        amount: "-5"
      } },
      { type: "RejectedTransfer", data: {
        id: "rejected-transfer-1",
        inflow_transaction_id: "missing-inflow",
        outflow_transaction_id: "missing-outflow"
      } }
    ]))

    result = I18n.with_locale(:de) { @import.sure_preflight }

    assert_includes result.errors, {
      code: "missing_reference",
      message: 'Zeile 1: Transaction verweist über account_id="missing-account" auf einen nicht vorhandenen Datensatz.'
    }
    assert_includes result.warnings, {
      code: "skipped_missing_reference",
      message: 'Zeile 2: RejectedTransfer verweist über inflow_transaction_id="missing-inflow" auf einen nicht vorhandenen Datensatz. Der Datensatz in dieser Zeile wird beim Import übersprungen.'
    }
  end

  test "preflight rejects invalid accountable types through explicit allowlist" do
    attach_ndjson(build_ndjson([
      { type: "Account", data: {
        id: "account-1",
        name: "Bad Accountable",
        balance: "100",
        accountable_type: "Kernel",
        accountable: { subtype: "system" }
      } }
    ]))

    result = @import.sure_preflight

    assert_not result.valid?
    assert_nil Accountable.from_type("Kernel")
    assert_equal Depository, Accountable.from_type("Depository")
    assert_equal [ "invalid_accountable_type" ], result.errors.map { |error| error[:code] }
    assert_includes result.error_message, 'invalid accountable_type "Kernel"'
  end

  test "preflight catches duplicate taxonomy names inside ndjson" do
    attach_ndjson(build_ndjson([
      { type: "Category", data: { id: "category-1", name: "Groceries" } },
      { type: "Category", data: { id: "category-2", name: "Groceries" } }
    ]))

    result = @import.sure_preflight

    assert_not result.valid?
    assert_includes result.errors.map { |error| error[:code] }, "duplicate_taxonomy_name"
    assert_includes result.error_message, "appears more than once"
  end

  test "preflight rejects split line totals that cannot import atomically" do
    attach_ndjson(build_ndjson([
      { type: "Account", data: {
        id: "split-account",
        name: "Split Checking",
        balance: "500.00",
        currency: "USD",
        accountable_type: "Depository"
      } },
      { type: "Transaction", data: {
        id: "split-parent",
        account_id: "split-account",
        date: "2024-01-15",
        amount: "100.00",
        name: "Invalid split parent",
        currency: "USD",
        split_lines: [
          { id: "split-child-1", amount: "40.00", name: "Split child one" },
          { id: "split-child-2", amount: "50.00", name: "Split child two" }
        ]
      } }
    ]))

    result = @import.sure_preflight

    assert_not result.valid?
    assert_includes result.errors.map { |error| error[:code] }, "split_amount_mismatch"

    assert_no_enqueued_jobs do
      assert_raises SureImport::PreflightError do
        @import.publish_later
      end
    end
    assert_equal "failed", @import.reload.status
  end

  test "strict preflight requires references to be present in the same ndjson" do
    existing_account = @family.accounts.first
    existing_parent = @family.categories.create!(
      name: "Existing Parent",
      color: "#407706",
      lucide_icon: "shapes"
    )

    attach_ndjson(build_ndjson([
      {
        type: "Valuation",
        data: {
          account_id: existing_account.id,
          date: "2024-01-01",
          amount: "100"
        }
      },
      {
        type: "Category",
        data: {
          id: "category-child",
          name: "Imported Child",
          parent_id: existing_parent.id
        }
      }
    ]))

    result = @import.sure_preflight

    assert_not result.valid?
    assert_equal(
      [ "missing_reference", "missing_reference" ],
      result.errors.map { |error| error[:code] }
    )
    assert_includes result.error_message, "references missing account_id"
    assert_includes result.error_message, "references missing parent_id"
  end

  test "provider merchant referenced by a transaction resolves during preflight and publish" do
    attach_ndjson(build_ndjson([
      { type: "Account", data: {
        id: "account-1",
        name: "Provider Merchant Checking",
        balance: "1000.00",
        currency: "USD",
        accountable_type: "Depository",
        accountable: { subtype: "checking" }
      } },
      { type: "ProviderMerchant", data: {
        id: "provider-merchant-1",
        name: "AMZN MKTP",
        source: "plaid",
        provider_merchant_id: "plaid_amzn"
      } },
      { type: "Transaction", data: {
        id: "transaction-1",
        account_id: "account-1",
        merchant_id: "provider-merchant-1",
        date: "2024-01-15",
        amount: "42.50",
        name: "Amazon purchase",
        currency: "USD"
      } }
    ]))

    result = @import.sure_preflight
    assert result.valid?, result.error_message

    assert_difference -> { ProviderMerchant.count }, 1 do
      @import.publish
    end

    assert_equal "complete", @import.status

    entry = @family.entries.find_by!(name: "Amazon purchase")
    merchant = entry.entryable.merchant

    assert_instance_of ProviderMerchant, merchant
    assert_equal "AMZN MKTP", merchant.name
    assert_equal "plaid", merchant.source
    assert_equal "plaid_amzn", merchant.provider_merchant_id
  end

  test "provider merchant import reuses an existing matching record instead of duplicating or overwriting it" do
    existing = ProviderMerchant.create!(
      name: "AMZN MKTP", source: "plaid", provider_merchant_id: "plaid_amzn", website_url: "https://amazon.com"
    )

    attach_ndjson(build_ndjson([
      { type: "Account", data: {
        id: "account-1",
        name: "Provider Merchant Checking",
        balance: "1000.00",
        currency: "USD",
        accountable_type: "Depository",
        accountable: { subtype: "checking" }
      } },
      { type: "ProviderMerchant", data: {
        id: "provider-merchant-1",
        name: "AMZN MKTP",
        source: "plaid",
        provider_merchant_id: "plaid_amzn",
        website_url: "https://should-not-overwrite.example.com"
      } },
      { type: "Transaction", data: {
        id: "transaction-1",
        account_id: "account-1",
        merchant_id: "provider-merchant-1",
        date: "2024-01-15",
        amount: "42.50",
        name: "Amazon purchase",
        currency: "USD"
      } }
    ]))

    assert_no_difference -> { ProviderMerchant.count } do
      @import.publish
    end

    assert_equal "complete", @import.status

    existing.reload
    assert_equal "https://amazon.com", existing.website_url

    entry = @family.entries.find_by!(name: "Amazon purchase")
    assert_equal existing.id, entry.entryable.merchant_id
  end

  test "provider merchant import never writes to an existing match, even when its fields are blank" do
    existing = ProviderMerchant.create!(name: "AMZN MKTP", source: "plaid", provider_merchant_id: "plaid_amzn")

    attach_ndjson(provider_merchant_ndjson(
      website_url: "https://amazon.com", logo_url: "https://cdn.example.com/amzn.png", color: "#123456"
    ))

    assert_no_difference -> { ProviderMerchant.count } do
      @import.publish
    end

    assert_equal "complete", @import.status
    existing.reload
    assert_nil existing.website_url
    assert_nil existing.logo_url
    assert_nil existing.color
    assert_equal existing.id, @family.entries.find_by!(name: "Amazon purchase").entryable.merchant_id
  end

  test "a color in the file is not read when a provider merchant is created" do
    attach_ndjson(provider_merchant_ndjson(color: "#123456"))

    assert_difference -> { ProviderMerchant.count }, 1 do
      @import.publish
    end

    assert_equal "complete", @import.status
    assert_nil ProviderMerchant.where(name: "AMZN MKTP", source: "plaid").pick(:color)
  end

  {
    "RecordNotUnique" => -> { ActiveRecord::RecordNotUnique.new("duplicate key") },
    "RecordInvalid" => -> { ActiveRecord::RecordInvalid.new(ProviderMerchant.new.tap { |merchant| merchant.errors.add(:name, :taken) }) }
  }.each do |label, build_error|
    test "provider merchant import recovers when another import wins the creation race (#{label})" do
      winner = ProviderMerchant.create!(name: "AMZN MKTP", source: "plaid", provider_merchant_id: "plaid_amzn")
      attach_ndjson(provider_merchant_ndjson)

      ProviderMerchant.stubs(:find_by_import_data).returns(nil).then.returns(winner)
      ProviderMerchant.stubs(:create!).raises(build_error.call)

      assert_no_difference -> { ProviderMerchant.count } do
        @import.import!
      end

      assert_equal winner.id, @family.entries.find_by!(name: "Amazon purchase").entryable.merchant_id
    end
  end

  test "provider merchant import surfaces validation errors that are not a lost creation race" do
    attach_ndjson(provider_merchant_ndjson)
    invalid = ActiveRecord::RecordInvalid.new(ProviderMerchant.new.tap { |merchant| merchant.errors.add(:name, :blank) })
    ProviderMerchant.stubs(:find_by_import_data).returns(nil)
    ProviderMerchant.stubs(:create!).raises(invalid)

    assert_raises(ActiveRecord::RecordInvalid) { @import.import! }
  end

  test "preflight warns with the actual diff when an existing provider merchant differs from the file" do
    ProviderMerchant.create!(name: "AMZN MKTP", source: "plaid", provider_merchant_id: "plaid_amzn", website_url: "https://amazon.com")
    attach_ndjson(provider_merchant_ndjson(website_url: "https://amazon.co.uk"))

    result = @import.sure_preflight

    assert result.valid?, result.error_message
    assert_equal 1, result.provider_merchant_diff_warnings.size
    details = result.provider_merchant_diff_warnings.first[:details]
    assert_equal "AMZN MKTP", details[:merchant_name]
    assert_equal(
      [ { field: "website_url", imported_value: "https://amazon.co.uk", kept_value: "https://amazon.com" } ],
      details[:diff]
    )
  end

  test "preflight does not warn when the provider merchant is new or identical" do
    attach_ndjson(provider_merchant_ndjson(website_url: "https://amazon.com"))
    assert_empty @import.sure_preflight.provider_merchant_diff_warnings

    ProviderMerchant.create!(name: "AMZN MKTP", source: "plaid", provider_merchant_id: "plaid_amzn", website_url: "https://amazon.com")
    assert_empty @import.sure_preflight.provider_merchant_diff_warnings
  end

  test "a transaction merchant_id unresolvable in the export is a warning, not a blocking preflight error (#3113)" do
    attach_ndjson(build_ndjson([
      { type: "Account", data: {
        id: "account-1",
        name: "Old Export Checking",
        balance: "1000.00",
        currency: "USD",
        accountable_type: "Depository",
        accountable: { subtype: "checking" }
      } },
      { type: "Transaction", data: {
        id: "transaction-1",
        account_id: "account-1",
        merchant_id: "merchant-never-exported",
        date: "2024-01-15",
        amount: "42.50",
        name: "Amazon purchase",
        currency: "USD"
      } }
    ]))

    result = @import.sure_preflight
    assert result.valid?, result.error_message
    assert_equal 1, result.skipped_missing_merchant_count
    assert result.warnings.any? { |warning| warning[:code] == "skipped_missing_merchant_reference" }

    @import.publish

    assert_equal "complete", @import.status
    entry = @family.entries.find_by!(name: "Amazon purchase")
    assert_nil entry.entryable.merchant_id
  end

  test "a missing account_id (not merchant_id) on a transaction is still a blocking preflight error" do
    attach_ndjson(build_ndjson([
      { type: "Transaction", data: {
        id: "transaction-1",
        account_id: "missing-account",
        date: "2024-01-15",
        amount: "42.50",
        name: "Orphaned transaction",
        currency: "USD"
      } }
    ]))

    result = @import.sure_preflight

    assert_not result.valid?
    assert_equal 0, result.skipped_missing_merchant_count
    assert result.errors.any? { |error| error[:code] == "missing_reference" }
  end

  test "publishing reuses an existing family category, tag and merchant matched by name instead of failing (#3113)" do
    existing_category = @family.categories.create!(name: "Groceries", color: "#111111", lucide_icon: "shapes")
    existing_tag = @family.tags.create!(name: "Reviewed", color: "#222222")
    existing_merchant = @family.merchants.create!(name: "Local Cafe", color: "#333333")

    category_count = @family.categories.count
    tag_count = @family.tags.count
    merchant_count = @family.merchants.count

    attach_ndjson(build_ndjson([
      { type: "Category", data: { id: "category-1", name: "Groceries", color: "#407706", lucide_icon: "shopping-cart" } },
      { type: "Tag", data: { id: "tag-1", name: "Reviewed", color: "#12B76A" } },
      { type: "Merchant", data: { id: "merchant-1", name: "Local Cafe", color: "#12B76A" } }
    ]))

    result = @import.sure_preflight
    assert result.valid?, result.error_message
    assert_equal 3, result.warnings.count { |warning| warning[:code] == "existing_taxonomy_collision" }

    @import.publish

    assert_equal "complete", @import.status
    assert_equal category_count, @family.categories.count
    assert_equal tag_count, @family.tags.count
    assert_equal merchant_count, @family.merchants.count

    assert_equal "#407706", existing_category.reload.color
    assert_equal "#12B76A", existing_tag.reload.color
    assert_equal "#12B76A", existing_merchant.reload.color

    @import.reload
    assert_equal "matched", @import.verification_status
    assert_equal({ "categories" => 1, "tags" => 1, "merchants" => 1 }, @import.readback_verification["reused_record_counts"])
  end

  test "family merchant import carries website_url and leaves an existing one alone when the file omits it" do
    kept = @family.merchants.create!(name: "Kept Cafe", website_url: "https://kept.example")
    updated = @family.merchants.create!(name: "Updated Cafe", website_url: "https://old.example")

    attach_ndjson(build_ndjson([
      { type: "Merchant", data: { id: "m-new", name: "New Cafe", website_url: "https://new.example" } },
      { type: "Merchant", data: { id: "m-kept", name: "Kept Cafe" } },
      { type: "Merchant", data: { id: "m-updated", name: "Updated Cafe", website_url: "https://fresh.example" } }
    ]))

    @import.publish

    assert_equal "complete", @import.status
    assert_equal "https://new.example", @family.merchants.find_by!(name: "New Cafe").website_url
    assert_equal "https://kept.example", kept.reload.website_url
    assert_equal "https://fresh.example", updated.reload.website_url
  end

  test "a named recurring transaction whose merchant is missing imports without a merchant" do
    attach_ndjson(recurring_with_missing_merchant_ndjson(name: "Gym membership"))

    result = @import.sure_preflight
    assert result.valid?, result.error_message
    assert_equal 1, result.skipped_missing_merchant_count
    assert_equal 0, result.skipped_unnamed_recurring_count

    assert_difference -> { @family.recurring_transactions.count }, 1 do
      @import.publish
    end

    assert_equal "complete", @import.status
    recurring = @family.recurring_transactions.find_by!(name: "Gym membership")
    assert_nil recurring.merchant_id
  end

  test "an unnamed recurring transaction whose merchant is missing is skipped and reported as such" do
    attach_ndjson(recurring_with_missing_merchant_ndjson)

    result = @import.sure_preflight
    assert result.valid?, result.error_message
    assert_equal 1, result.skipped_unnamed_recurring_count
    assert_equal 0, result.skipped_missing_merchant_count

    assert_no_difference -> { @family.recurring_transactions.count } do
      @import.publish
    end

    assert_equal "complete", @import.status
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

    def provider_merchant_ndjson(**merchant_attrs)
      build_ndjson([
        { type: "Account", data: {
          id: "account-1", name: "Provider Merchant Checking", balance: "1000.00", currency: "USD",
          accountable_type: "Depository", accountable: { subtype: "checking" }
        } },
        { type: "ProviderMerchant", data: {
          id: "provider-merchant-1", name: "AMZN MKTP", source: "plaid", provider_merchant_id: "plaid_amzn"
        }.merge(merchant_attrs) },
        { type: "Transaction", data: {
          id: "transaction-1", account_id: "account-1", merchant_id: "provider-merchant-1",
          date: "2024-01-15", amount: "42.50", name: "Amazon purchase", currency: "USD"
        } }
      ])
    end

    def recurring_with_missing_merchant_ndjson(**recurring_attrs)
      build_ndjson([
        { type: "Account", data: {
          id: "account-1", name: "Recurring Checking", balance: "1000.00", currency: "USD",
          accountable_type: "Depository", accountable: { subtype: "checking" }
        } },
        { type: "RecurringTransaction", data: {
          id: "recurring-1", account_id: "account-1", merchant_id: "merchant-never-exported",
          amount: "11.99", currency: "USD", expected_day_of_month: 28,
          last_occurrence_date: "2026-08-28", next_expected_date: "2026-09-28"
        }.merge(recurring_attrs) }
      ])
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

class Import::PreflightTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "SureImport preflight reuses an existing taxonomy match by name instead of blocking (#3113)" do
    @family.tags.create!(name: "Reviewed", color: "#12B76A")
    ndjson = build_ndjson([
      { type: "Tag", data: { id: "tag-1", name: "Reviewed" } }
    ])

    assert_no_difference("Import.count") do
      response = Import::Preflight.new(
        family: @family,
        params: { type: "SureImport", raw_file_content: ndjson }
      ).call
      payload = response.payload[:data]

      assert_equal :ok, response.status
      assert_equal true, payload[:valid]
      assert_empty payload[:errors]
      assert_includes payload[:warnings], "Line 1 Tag name \"Reviewed\" already exists in this family and will be reused."
    end
  end

  test "SureImport preflight counts invalid rows instead of validation errors" do
    ndjson = build_ndjson([
      [],
      { type: "Transaction", data: { id: "transaction-1" } }
    ])

    response = Import::Preflight.new(
      family: @family,
      params: { type: "SureImport", raw_file_content: ndjson }
    ).call
    payload = response.payload[:data]

    assert_equal :ok, response.status
    assert_equal 2, payload[:stats][:rows_count]
    assert_equal 1, payload[:stats][:valid_rows_count]
    assert_equal 1, payload[:stats][:invalid_rows_count]
    assert_operator payload[:errors].size, :>, payload[:stats][:invalid_rows_count]
  end

  test "SureImport preflight handles missing entity counts" do
    result = Struct.new(:stats, :errors, :warnings, keyword_init: true) do
      def valid?
        true
      end
    end.new(
      stats: { rows_count: 1, valid_rows_count: 1, invalid_rows_count: 0 },
      errors: [],
      warnings: []
    )
    SureImport::Preflight.stubs(:new).returns(stub(call: result))

    response = Import::Preflight.new(
      family: @family,
      params: { type: "SureImport", raw_file_content: "{}" }
    ).call
    payload = response.payload[:data]

    assert_equal :ok, response.status
    assert_includes payload[:warnings], "No importable records were found."
  end

  test "SureImport preflight serializes hash warnings as strings at the API boundary" do
    result = Struct.new(:stats, :errors, :warnings, keyword_init: true) do
      def valid?
        true
      end
    end.new(
      stats: { rows_count: 2, valid_rows_count: 2, invalid_rows_count: 0, entity_counts: { accounts: 2 } },
      errors: [],
      warnings: [ { code: "skipped_missing_reference", message: "Skipped an orphaned rejected transfer." } ]
    )
    SureImport::Preflight.stubs(:new).returns(stub(call: result))

    response = Import::Preflight.new(
      family: @family,
      params: { type: "SureImport", raw_file_content: "{}" }
    ).call
    payload = response.payload[:data]

    # The contract documents warnings as strings, so the {code, message} hash must
    # surface as its message -- never leak the hash into the response.
    assert payload[:warnings].all? { |warning| warning.is_a?(String) }, "preflight warnings must be strings"
    assert_includes payload[:warnings], "Skipped an orphaned rejected transfer."
  end

  private

    def build_ndjson(records)
      records.map(&:to_json).join("\n")
    end
end
