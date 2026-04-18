require "test_helper"

class SimplefinAccount::ActivitySummaryTest < ActiveSupport::TestCase
  def build(transactions)
    SimplefinAccount::ActivitySummary.new(transactions)
  end

  def tx(date: nil, amount: -10.0, posted: nil, pending: false, payee: "Test")
    {
      "id" => "TRN-#{SecureRandom.hex(4)}",
      "amount" => amount.to_s,
      "posted" => (posted.nil? ? 0 : posted.to_i),
      "pending" => pending,
      "payee" => payee,
      "description" => payee.upcase,
      "transacted_at" => (date || Time.current).to_i
    }
  end

  test "empty payload is dormant with nil last_transacted_at and zero counts" do
    summary = build([])
    assert_nil summary.last_transacted_at
    assert_equal 0, summary.transaction_count
    assert_equal 0, summary.recent_transaction_count
    assert summary.dormant?
    refute summary.recently_active?
  end

  test "nil payload is treated as empty" do
    summary = build(nil)
    assert summary.dormant?
    assert_equal 0, summary.transaction_count
  end

  test "last_transacted_at returns the most recent transaction time" do
    latest = 3.days.ago
    summary = build([
      tx(date: 30.days.ago),
      tx(date: latest),
      tx(date: 10.days.ago)
    ])
    assert_in_delta latest.to_i, summary.last_transacted_at.to_i, 2
  end

  test "recent_transaction_count counts within default 60-day window" do
    summary = build([
      tx(date: 30.days.ago),
      tx(date: 45.days.ago),
      tx(date: 90.days.ago),
      tx(date: 120.days.ago)
    ])
    assert_equal 2, summary.recent_transaction_count
  end

  test "recent_transaction_count honors custom window" do
    summary = build([
      tx(date: 10.days.ago),
      tx(date: 20.days.ago),
      tx(date: 40.days.ago)
    ])
    assert_equal 1, summary.recent_transaction_count(days: 15)
    assert_equal 3, summary.recent_transaction_count(days: 90)
  end

  test "falls back to posted when transacted_at is zero (unknown)" do
    # SimpleFIN uses 0 to signal "unknown" for transacted_at. Because 0 is
    # truthy in Ruby, a naive `transacted_at || posted` short-circuits to 0
    # and never falls back. Verify the fallback still produces the posted time.
    posted_ts = 5.days.ago.to_i
    summary = SimplefinAccount::ActivitySummary.new([
      { "transacted_at" => 0, "posted" => posted_ts, "amount" => "-5" }
    ])
    assert_equal Time.at(posted_ts), summary.last_transacted_at
  end

  test "dormant? returns true when no activity within window" do
    summary = build([ tx(date: 120.days.ago) ])
    assert summary.dormant?
    refute summary.recently_active?
  end

  test "dormant? returns false when any recent activity exists" do
    summary = build([ tx(date: 120.days.ago), tx(date: 3.days.ago) ])
    refute summary.dormant?
    assert summary.recently_active?
  end

  test "days_since_last_activity returns whole days since newest tx" do
    summary = build([ tx(date: 37.days.ago) ])
    assert_equal 37, summary.days_since_last_activity
  end

  test "days_since_last_activity is nil when no transactions" do
    assert_nil build([]).days_since_last_activity
  end

  test "ignores transactions with zero transacted_at and zero posted" do
    # SimpleFIN uses posted=0 for pending; malformed entries may have transacted_at=0
    summary = build([
      { "id" => "a", "transacted_at" => 0, "posted" => 0, "amount" => "-5" },
      tx(date: 3.days.ago)
    ])
    assert_in_delta 3.days.ago.to_i, summary.last_transacted_at.to_i, 2
    assert_equal 1, summary.recent_transaction_count
  end

  test "falls back to posted when transacted_at is absent" do
    posted_time = 5.days.ago.to_i
    summary = build([
      { "id" => "a", "amount" => "-5", "posted" => posted_time, "pending" => false }
    ])
    assert_in_delta posted_time, summary.last_transacted_at.to_i, 2
    assert_equal 1, summary.recent_transaction_count
  end

  test "accepts symbol-keyed transaction hashes" do
    summary = build([
      { transacted_at: 3.days.ago.to_i, amount: "-5", id: "a" },
      { "transacted_at" => 3.days.ago.to_i, "amount" => "-5", "id" => "b" }
    ])
    assert_equal 2, summary.recent_transaction_count
  end
end

class SimplefinAccountActivitySummaryIntegrationTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(
      family: @family,
      name: "SF Conn",
      access_url: "https://example.com/access"
    )
  end

  test "#activity_summary wraps raw_transactions_payload" do
    sfa = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "Active Card",
      account_id: "sf-active",
      account_type: "credit",
      currency: "USD",
      current_balance: -100,
      raw_transactions_payload: [
        {
          "id" => "t1",
          "amount" => "-50",
          "posted" => 3.days.ago.to_i,
          "transacted_at" => 3.days.ago.to_i
        }
      ]
    )
    summary = sfa.activity_summary
    assert_kind_of SimplefinAccount::ActivitySummary, summary
    assert summary.recently_active?
    assert_equal 1, summary.transaction_count
  end

  test "#activity_summary handles nil raw_transactions_payload" do
    sfa = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "Empty Card",
      account_id: "sf-empty",
      account_type: "credit",
      currency: "USD",
      current_balance: 0,
      raw_transactions_payload: nil
    )
    summary = sfa.activity_summary
    assert_equal 0, summary.transaction_count
    assert summary.dormant?
  end
end
