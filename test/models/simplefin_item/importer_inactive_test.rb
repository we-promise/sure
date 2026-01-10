require "test_helper"

class SimplefinItem::ImporterInactiveTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(family: @family, name: "SF Conn", access_url: "https://example.com/access")
    @sync = Sync.create!(syncable: @item)
  end

  def importer
    @importer ||= SimplefinItem::Importer.new(@item, simplefin_provider: mock(), sync: @sync)
  end

  test "marks inactive when payload indicates closed or hidden" do
    account_data = { id: "a1", name: "Old Checking", balance: 0, currency: "USD", closed: true }
    importer.send(:import_account, account_data)

    stats = @sync.reload.sync_stats
    assert stats.dig("inactive", "a1"), "should be inactive when closed flag present"
  end

  test "counts zero runs once per sync even with multiple imports" do
    account_data = { id: "a2", name: "Dormant", balance: 0, "available-balance": 0, currency: "USD" }

    # Multiple imports in the same sync (simulating chunked imports) should only count once
    5.times { importer.send(:import_account, account_data) }

    stats = @sync.reload.sync_stats
    assert_equal 1, stats.dig("zero_runs", "a2"), "should only count once per sync despite multiple imports"
    assert_equal false, stats.dig("inactive", "a2"), "should not be inactive after single count"
  end

  test "resets zero_runs and inactive when activity returns" do
    account_data = { id: "a3", name: "Dormant", balance: 0, "available-balance": 0, currency: "USD" }
    importer.send(:import_account, account_data)

    stats = @sync.reload.sync_stats
    assert_equal 1, stats.dig("zero_runs", "a3")

    # Activity returns: non-zero balance
    active_data = { id: "a3", name: "Dormant", balance: 10, currency: "USD" }
    importer.send(:import_account, active_data)

    stats = @sync.reload.sync_stats
    assert_equal 0, stats.dig("zero_runs", "a3")
    assert_equal false, stats.dig("inactive", "a3")
  end

  test "does not count zero run when both balances are missing and no holdings" do
    account_data = { id: "a4", name: "Unknown", currency: "USD" } # no balance keys, no holdings

    importer.send(:import_account, account_data)
    stats = @sync.reload.sync_stats

    assert_equal 0, stats.dig("zero_runs", "a4").to_i
    assert_equal false, stats.dig("inactive", "a4")
  end

  test "skips zero balance detection for credit cards" do
    # Create a SimplefinAccount linked to a CreditCard account
    sfa = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "Paid Off Card",
      account_id: "cc1",
      account_type: "credit",
      currency: "USD",
      current_balance: 0
    )

    credit_card = CreditCard.create!
    account = @family.accounts.create!(
      name: "Paid Off Card",
      balance: 0,
      currency: "USD",
      accountable: credit_card,
      simplefin_account_id: sfa.id
    )

    account_data = { id: "cc1", name: "Paid Off Card", balance: 0, "available-balance": 0, currency: "USD" }

    # Even with zero balance and no holdings, credit cards should not trigger the counter
    importer.send(:import_account, account_data)
    stats = @sync.reload.sync_stats

    assert_nil stats.dig("zero_runs", "cc1"), "should not count zero runs for credit cards"
    assert_equal false, stats.dig("inactive", "cc1")
  end

  test "skips zero balance detection for loans" do
    # Create a SimplefinAccount linked to a Loan account
    sfa = SimplefinAccount.create!(
      simplefin_item: @item,
      name: "Paid Off Loan",
      account_id: "loan1",
      account_type: "loan",
      currency: "USD",
      current_balance: 0
    )

    loan = Loan.create!
    account = @family.accounts.create!(
      name: "Paid Off Loan",
      balance: 0,
      currency: "USD",
      accountable: loan,
      simplefin_account_id: sfa.id
    )

    account_data = { id: "loan1", name: "Paid Off Loan", balance: 0, "available-balance": 0, currency: "USD" }

    # Even with zero balance and no holdings, loans should not trigger the counter
    importer.send(:import_account, account_data)
    stats = @sync.reload.sync_stats

    assert_nil stats.dig("zero_runs", "loan1"), "should not count zero runs for loans"
    assert_equal false, stats.dig("inactive", "loan1")
  end
end
