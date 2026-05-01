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
    assert_equal 100_000, @import.max_row_count
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
