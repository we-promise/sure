require "test_helper"

class BulkImportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @family = families(:dylan_family)
    @import = @family.imports.create!(type: "BulkImport")
  end

  test "import interface methods exist" do
    assert_respond_to @import, :publish
    assert_respond_to @import, :publish_later
    assert_respond_to @import, :generate_rows_from_csv
    assert_respond_to @import, :uploaded?
    assert_respond_to @import, :configured?
    assert_respond_to @import, :cleaned?
    assert_respond_to @import, :publishable?
    assert_respond_to @import, :importing?
    assert_respond_to @import, :complete?
    assert_respond_to @import, :failed?
  end

  test "column_keys returns empty array" do
    assert_equal [], @import.column_keys
  end

  test "required_column_keys returns empty array" do
    assert_equal [], @import.required_column_keys
  end

  test "mapping_steps returns empty array" do
    assert_equal [], @import.mapping_steps
  end

  test "max_row_count is higher than standard imports" do
    assert_equal 100_000, @import.max_row_count
  end

  test "csv_template returns nil" do
    assert_nil @import.csv_template
  end

  test "uploaded? returns false without ndjson content" do
    assert_not @import.uploaded?
  end

  test "uploaded? returns true with valid ndjson content" do
    ndjson = build_ndjson([
      { type: "Account", data: { id: "uuid-1", name: "Test", balance: "1000", currency: "USD", accountable_type: "Depository" } }
    ])
    @import.update!(raw_file_str: ndjson)

    assert @import.uploaded?
  end

  test "uploaded? returns false with invalid ndjson content" do
    @import.update!(raw_file_str: "not valid json")

    assert_not @import.uploaded?
  end

  test "configured? returns true when uploaded" do
    ndjson = build_ndjson([
      { type: "Account", data: { id: "uuid-1", name: "Test", balance: "1000", currency: "USD", accountable_type: "Depository" } }
    ])
    @import.update!(raw_file_str: ndjson)

    assert @import.configured?
  end

  test "cleaned? returns true when uploaded" do
    ndjson = build_ndjson([
      { type: "Account", data: { id: "uuid-1", name: "Test", balance: "1000", currency: "USD", accountable_type: "Depository" } }
    ])
    @import.update!(raw_file_str: ndjson)

    assert @import.cleaned?
  end

  test "publishable? returns true when uploaded and valid" do
    ndjson = build_ndjson([
      { type: "Account", data: { id: "uuid-1", name: "Test", balance: "1000", currency: "USD", accountable_type: "Depository" } }
    ])
    @import.update!(raw_file_str: ndjson)

    assert @import.publishable?
  end

  test "dry_run returns counts by type" do
    ndjson = build_ndjson([
      { type: "Account", data: { id: "uuid-1" } },
      { type: "Account", data: { id: "uuid-2" } },
      { type: "Category", data: { id: "uuid-3" } },
      { type: "Transaction", data: { id: "uuid-4" } },
      { type: "Transaction", data: { id: "uuid-5" } },
      { type: "Transaction", data: { id: "uuid-6" } }
    ])
    @import.update!(raw_file_str: ndjson)

    dry_run = @import.dry_run

    assert_equal 2, dry_run[:accounts]
    assert_equal 1, dry_run[:categories]
    assert_equal 3, dry_run[:transactions]
    assert_equal 0, dry_run[:tags]
  end

  test "generate_rows_from_csv sets total row count" do
    ndjson = build_ndjson([
      { type: "Account", data: { id: "uuid-1" } },
      { type: "Category", data: { id: "uuid-2" } },
      { type: "Transaction", data: { id: "uuid-3" } }
    ])
    @import.update!(raw_file_str: ndjson)

    @import.generate_rows_from_csv

    assert_equal 3, @import.rows_count
  end

  test "publishes import successfully" do
    ndjson = build_ndjson([
      { type: "Account", data: {
        id: "uuid-1",
        name: "Import Test Account",
        balance: "1000.00",
        currency: "USD",
        accountable_type: "Depository",
        accountable: { subtype: "checking" }
      } }
    ])
    @import.update!(raw_file_str: ndjson)

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
    ndjson = build_ndjson([
      { type: "Account", data: {
        id: "uuid-1",
        name: "Revertable Account",
        balance: "500.00",
        currency: "USD",
        accountable_type: "Depository"
      } }
    ])
    @import.update!(raw_file_str: ndjson)

    @import.publish

    assert_equal 1, @import.accounts.count
    assert_equal "Revertable Account", @import.accounts.first.name
  end

  test "publishes later enqueues job" do
    ndjson = build_ndjson([
      { type: "Account", data: {
        id: "uuid-1",
        name: "Async Account",
        balance: "100",
        currency: "USD",
        accountable_type: "Depository"
      } }
    ])
    @import.update!(raw_file_str: ndjson)

    assert_enqueued_with job: ImportJob, args: [ @import ] do
      @import.publish_later
    end

    assert_equal "importing", @import.status
  end

  private

  def build_ndjson(records)
    records.map(&:to_json).join("\n")
  end
end
