# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261007100000_add_unique_index_for_valuation_per_account_and_date")

# The index build itself runs CONCURRENTLY and can't run inside the test
# transaction, so these cover the duplicate cleanup that runs before it.
class AddUniqueIndexForValuationPerAccountAndDateMigrationTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:depository)
    @date = Date.new(2026, 1, 15)
    ActiveRecord::Base.connection.execute("DROP INDEX IF EXISTS #{AddUniqueIndexForValuationPerAccountAndDate::INDEX_NAME}")
  end

  test "keeps the most recently updated valuation per account and date" do
    older = valuation(amount: 1000, updated_at: 2.days.ago)
    newer = valuation(amount: 1200, updated_at: 1.day.ago)

    assert_difference [ "Entry.count", "Valuation.count" ], -1 do
      remove_duplicates
    end

    assert Entry.exists?(newer.id)
    assert_not Entry.exists?(older.id)
    assert_not Valuation.exists?(older.entryable_id)
  end

  test "leaves single valuations and other dates and accounts alone" do
    other_date = valuation(amount: 900, date: @date - 1)
    other_account = valuation(amount: 800, account: accounts(:credit_card))
    single = valuation(amount: 1000)

    assert_no_difference "Entry.count" do
      remove_duplicates
    end

    assert Entry.exists?(other_date.id)
    assert Entry.exists?(other_account.id)
    assert Entry.exists?(single.id)
  end

  test "can run twice" do
    valuation(amount: 1000, updated_at: 2.days.ago)
    newer = valuation(amount: 1200, updated_at: 1.day.ago)

    remove_duplicates
    assert_no_difference "Entry.count" do
      remove_duplicates
    end

    assert Entry.exists?(newer.id)
  end

  private
    def remove_duplicates
      migration = AddUniqueIndexForValuationPerAccountAndDate.new
      migration.verbose = false
      migration.send(:remove_duplicate_valuations)
    end

    # Entry validates one valuation per account and date, so the duplicate
    # the race leaves behind is written past validations.
    def valuation(amount:, date: @date, account: @account, updated_at: Time.current)
      entry = account.entries.new(
        name: "Manual value update", amount: amount, currency: account.currency, date: date,
        entryable: Valuation.new(kind: "reconciliation")
      )
      entry.save!(validate: false)
      entry.update_columns(updated_at: updated_at)
      entry
    end
end
