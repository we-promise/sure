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
      puts "DEBUG status=#{@import.reload.status} error=#{@import.reload.respond_to?(:error) ? @import.reload.error : 'n/a'}"
      puts "DEBUG entries remaining=#{Entry.where(id: split_entry_ids).count}"
      puts "DEBUG import entries count=#{@import.entries.where(parent_entry_id: nil).count}"
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
    @family.categories.create!(
      name: "Groceries",
      color: "#407706",
      lucide_icon: "shopping-basket"
    )
    attach_ndjson(build_ndjson([
      { type: "Account", data: {
        id: "account-1",
        name: "Blocked Account",
        balance: "100",
        currency: "USD",
        accountable_type: "Depository"
      } },
      { type: "Category", data: { id: "category-1", name: "Groceries" } }
    ]))

    assert_no_enqueued_jobs do
      assert_raises SureImport::PreflightError do
        @import.publish_later
      end
    end

    assert_equal "failed", @import.reload.status
    assert_includes @import.error, "Category name \"Groceries\" already exists"
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

class Import::PreflightTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "SureImport preflight reports strict taxonomy collisions" do
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
      assert_equal false, payload[:valid]
      assert_equal "existing_taxonomy_collision", payload[:errors].first[:code]
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

  private

    def build_ndjson(records)
      records.map(&:to_json).join("\n")
    end
end
