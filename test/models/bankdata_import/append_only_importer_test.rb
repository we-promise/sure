# frozen_string_literal: true

require "test_helper"

class BankdataImport::AppendOnlyImporterTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)
    @payload = bankdata_payload
  end

  test "preview reports creates without writing entries" do
    assert_no_difference "Entry.count" do
      summary = BankdataImport::AppendOnlyImporter.new(family: @family, payload: @payload, mode: :preview).call
      assert_equal 6, summary.created
      assert_equal 0, summary.already_imported
    end
  end

  test "import creates entries with source external id excluded flag and metadata" do
    summary = nil

    assert_difference "Entry.count", 6 do
      summary = BankdataImport::AppendOnlyImporter.new(family: @family, payload: @payload, mode: :import).call
    end

    entry = Entry.find_by!(source: "bankdata_pipeline", external_id: @payload["transactions"].first["external_id"])
    assert_equal 6, summary.created
    assert_equal "bankdata_pipeline", entry.source
    assert_predicate entry, :import_locked?
    assert_equal "5035K4308043014S0AD", entry.entryable.extra.dig("bankdata_pipeline", "source_transaction_id")
  end

  test "second import skips duplicates by source and external id" do
    BankdataImport::AppendOnlyImporter.new(family: @family, payload: @payload, mode: :import).call

    assert_no_difference "Entry.count" do
      summary = BankdataImport::AppendOnlyImporter.new(family: @family, payload: @payload, mode: :import).call
      assert_equal 0, summary.created
      assert_equal 6, summary.already_imported
    end
  end

  test "retry after partial import creates only missing rows" do
    partial = @payload.deep_dup
    partial["transactions"] = partial["transactions"].first(2)
    BankdataImport::AppendOnlyImporter.new(family: @family, payload: partial, mode: :import).call

    assert_difference "Entry.count", 4 do
      summary = BankdataImport::AppendOnlyImporter.new(family: @family, payload: @payload, mode: :import).call
      assert_equal 4, summary.created
      assert_equal 2, summary.already_imported
    end
  end

  test "does not overwrite existing edited entries" do
    BankdataImport::AppendOnlyImporter.new(family: @family, payload: @payload, mode: :import).call
    entry = Entry.find_by!(source: "bankdata_pipeline", external_id: @payload["transactions"].first["external_id"])
    entry.update!(name: "Edited in Sure")

    BankdataImport::AppendOnlyImporter.new(family: @family, payload: @payload, mode: :import).call

    assert_equal "Edited in Sure", entry.reload.name
  end

  test "imports uncategorized transaction when allowed" do
    payload = JSON.parse(file_fixture("bankdata_import_uncategorized_payload.json").read)
    payload["account_mappings"][0]["sure_account_id"] = @account.id

    summary = BankdataImport::AppendOnlyImporter.new(family: @family, payload: payload, mode: :import).call

    assert_equal 1, summary.created
    entry = @account.entries.find_by!(external_id: "bankdata_pipeline:Betaal:SQL-1")
    assert_nil entry.entryable.category
    assert_equal "NS GROEP IZ NS REIZIGERS", entry.entryable.merchant.name
  end

  test "re-importing uncategorized transaction is idempotent" do
    payload = JSON.parse(file_fixture("bankdata_import_uncategorized_payload.json").read)
    payload["account_mappings"][0]["sure_account_id"] = @account.id

    BankdataImport::AppendOnlyImporter.new(family: @family, payload: payload, mode: :import).call
    summary = BankdataImport::AppendOnlyImporter.new(family: @family, payload: payload, mode: :import).call

    assert_equal 0, summary.created
    assert_equal 1, summary.already_imported
  end

  private

    def bankdata_payload
      JSON.parse(file_fixture("bankdata_import_payload.json").read).tap do |payload|
        payload["account_mappings"][0]["sure_account_id"] = @account.id
      end
    end
end
