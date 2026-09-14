# frozen_string_literal: true

require "test_helper"

# simplefin:pending_restore un-excludes SimpleFIN/Plaid pending entries that have
# no posted match. "Pending" -- for the excluded entry and for its would-be
# match -- is decided as Transaction#pending? decides it, for those two providers.
class SimplefinPendingRestoreTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    RakeTaskTestHelper.load_task("simplefin:pending_restore", "simplefin_pending_cleanup")
    RakeTaskTestHelper.prepare("simplefin:pending_restore")

    @account = families(:empty).accounts.create!(name: "SF Checking", balance: 0, currency: "USD", accountable: Depository.new)
  end

  test "restores an excluded entry whose flag a boolean cast cannot parse" do
    entry = excluded_entry("simplefin" => { "pending" => "maybe" })

    restore

    assert_not entry.reload.excluded
  end

  test "restores an excluded entry flagged \"no\", which pending? calls pending" do
    entry = excluded_entry("plaid" => { "pending" => "no" })

    restore

    assert_not entry.reload.excluded
  end

  test "a companion flagged \"no\" is still pending, so it is not a posted match" do
    entry = excluded_entry("simplefin" => { "pending" => true })
    companion(entry, "plaid" => { "pending" => "no" })

    restore

    assert_not entry.reload.excluded
  end

  test "keeps an excluded entry that has a posted match" do
    entry = excluded_entry("simplefin" => { "pending" => true })
    companion(entry, {})

    restore

    assert entry.reload.excluded
  end

  test "leaves entries flagged pending by other providers alone" do
    entry = excluded_entry("lunchflow" => { "pending" => true })

    restore

    assert entry.reload.excluded
  end

  private

    def excluded_entry(extra)
      create_transaction(account: @account, amount: 25, date: 20.days.ago.to_date, excluded: true).tap do |entry|
        entry.entryable.update!(extra: extra)
      end
    end

    def companion(entry, extra)
      create_transaction(account: @account, amount: entry.amount, currency: entry.currency, date: entry.date + 2.days).tap do |companion_entry|
        companion_entry.entryable.update!(extra: extra)
      end
    end

    def restore
      previous = ENV["DRY_RUN"]
      ENV["DRY_RUN"] = "false"
      capture_io { Rake::Task["simplefin:pending_restore"].invoke }
    ensure
      ENV["DRY_RUN"] = previous
    end
end
