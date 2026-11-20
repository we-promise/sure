# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20261119090000_backfill_split_part_activity_labels")

class BackfillSplitPartActivityLabelsMigrationTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(
      name: "Brokerage", balance: 0, currency: "USD", accountable: Investment.new
    )
  end

  test "gives an unlabelled part its parent's activity label" do
    parts = split_with_unlabelled_parts(parent_label: "Dividend")

    run_migration

    assert_equal %w[Dividend Dividend], parts.map { |part| part.reload.investment_activity_label }
  end

  test "touches the relabelled parts' entries so entry-keyed caches rebuild" do
    parts = split_with_unlabelled_parts(parent_label: "Dividend")
    entries = parts.map(&:entry)
    entries.each { |entry| entry.update_columns(updated_at: 1.day.ago) }
    version_before = @family.entries_cache_version

    run_migration

    assert entries.all? { |entry| entry.reload.updated_at > 1.hour.ago }
    assert_not_equal version_before, @family.entries_cache_version
  end

  test "keeps a part's own activity label" do
    relabelled, unlabelled = split_with_unlabelled_parts(parent_label: "Dividend")
    relabelled.update_columns(investment_activity_label: "Fee")

    run_migration

    assert_equal "Fee", relabelled.reload.investment_activity_label
    assert_equal "Dividend", unlabelled.reload.investment_activity_label
  end

  test "leaves the parts of an unlabelled parent unlabelled" do
    parts = split_with_unlabelled_parts(parent_label: nil)

    run_migration

    assert parts.all? { |part| part.reload.investment_activity_label.nil? }
  end

  test "leaves a part whose label the user locked" do
    locked, _unlocked = split_with_unlabelled_parts(parent_label: "Interest")
    locked.update_columns(locked_attributes: { "investment_activity_label" => Time.current.iso8601 })

    run_migration

    assert_nil locked.reload.investment_activity_label
  end

  private

    # Parts split before split! copied the label carry none.
    def split_with_unlabelled_parts(parent_label:)
      parent = @account.entries.create!(
        name: "Income", date: Date.current, amount: -100, currency: "USD",
        entryable: Transaction.new(investment_activity_label: parent_label)
      )
      parts = parent.split!([ { name: "Part 1", amount: -60 }, { name: "Part 2", amount: -40 } ]).map(&:transaction)
      parts.each { |part| part.update_columns(investment_activity_label: nil) }
      parts
    end

    def run_migration
      ActiveRecord::Migration.suppress_messages do
        BackfillSplitPartActivityLabels.new.up
      end
    end
end
