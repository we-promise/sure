# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261124050000_move_auto_excluded_pending_marks_to_data_enrichments")

class MoveAutoExcludedPendingMarksToDataEnrichmentsMigrationTest < ActiveSupport::TestCase
  include EntriesTestHelper

  MARK = MoveAutoExcludedPendingMarksToDataEnrichments::MARK

  setup do
    @account = accounts(:depository)
  end

  test "turns a marked stale pending into a recorded automatic exclusion" do
    entry = create_marked_pending(excluded: true)

    run_migration(:up)

    entry.reload
    assert entry.auto_excluded_pending?
    assert_equal({ "reason" => "stale_pending", "provider" => "enable_banking", "days" => 8 }, entry.auto_exclusion.metadata)
    assert_equal({ "enable_banking" => { "pending" => true } }, entry.transaction.extra)
  end

  test "drops a mark left on an entry that is no longer excluded without recording it" do
    entry = create_marked_pending(excluded: false)

    run_migration(:up)

    entry.reload
    assert_empty entry.data_enrichments
    assert_not entry.transaction.extra.key?(MARK)
  end

  test "down puts the mark back" do
    entry = create_marked_pending(excluded: true)
    run_migration(:up)

    run_migration(:down)

    assert_equal true, entry.transaction.reload.extra[MARK]
  end

  private

    def create_marked_pending(excluded:)
      entry = create_transaction(
        account: @account, date: 10.days.ago.to_date, amount: 40,
        entryable: Transaction.new(extra: { "enable_banking" => { "pending" => true }, MARK => true })
      )
      entry.update_columns(source: "enable_banking", excluded: excluded)
      entry
    end

    def run_migration(direction)
      ActiveRecord::Migration.suppress_messages do
        MoveAutoExcludedPendingMarksToDataEnrichments.new.migrate(direction)
      end
    end
end
