require "test_helper"

# track_stale_unmatched_pending counts stale pending entries that have no posted
# match. It decides "pending" as Transaction#pending? does, across every pending
# provider, like the stale-pending exclusion that runs just before it.
class SimplefinItem::ImporterStaleUnmatchedPendingTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @item = SimplefinItem.create!(family: @family, name: "SF Conn", access_url: "https://example.com/access")
    @account = @family.accounts.create!(name: "SF Checking", balance: 0, currency: "USD", accountable: Depository.new)
    @importer = SimplefinItem::Importer.new(@item, simplefin_provider: mock(), sync: Sync.create!(syncable: @item))
  end

  test "counts a stale entry whose flag a boolean cast cannot parse, without recording an error" do
    stale_entry("simplefin" => { "pending" => "maybe" })

    track

    assert_nil stats["reconciliation_errors"]
    assert_equal 1, stats["stale_unmatched_pending"]
  end

  test "counts a stale entry flagged \"no\", which pending? calls pending" do
    stale_entry("simplefin" => { "pending" => "no" })

    track

    assert_equal 1, stats["stale_unmatched_pending"]
  end

  test "counts a stale entry pending under any provider, not only SimpleFIN and Plaid" do
    stale_entry("lunchflow" => { "pending" => true })

    track

    assert_equal 1, stats["stale_unmatched_pending"]
  end

  test "does not count stale entries that are not pending" do
    stale_entry("plaid" => { "pending" => "false" })
    stale_entry({})

    track

    assert_nil stats["reconciliation_errors"]
    assert_nil stats["stale_unmatched_pending"]
  end

  private

    def stale_entry(extra)
      create_transaction(account: @account, amount: 10, date: 10.days.ago.to_date).tap do |entry|
        entry.entryable.update!(extra: extra)
      end
    end

    def track
      @importer.send(:track_stale_unmatched_pending, @account)
    end

    def stats
      @importer.send(:stats)
    end
end
