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

  test "merge_existing_taxonomy allows explicit taxonomy reuse" do
    category = @family.categories.create!(
      name: "Groceries",
      color: "#407706",
      lucide_icon: "shopping-basket"
    )
    attach_ndjson(build_ndjson([
      { type: "Category", data: { id: "category-1", name: category.name } }
    ]))

    assert_not @import.sure_preflight.valid?

    @import.merge_existing_taxonomy = true

    assert @import.sure_preflight.valid?
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
end
