require "test_helper"

class CoinstatsAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @coinstats_item = CoinstatsItem.create!(
      family: @family,
      name: "Test CoinStats Connection",
      api_key: "test_api_key_123"
    )
    @crypto = Crypto.create!
    @account = @family.accounts.create!(
      accountable: @crypto,
      name: "Test Crypto Account",
      balance: 1000,
      currency: "USD"
    )
    @coinstats_account = @coinstats_item.coinstats_accounts.create!(
      name: "Test Wallet",
      currency: "USD",
      current_balance: 2500
    )
    AccountProvider.create!(account: @account, provider: @coinstats_account)
  end

  test "skips processing when no linked account" do
    # Create an unlinked coinstats account
    unlinked_account = @coinstats_item.coinstats_accounts.create!(
      name: "Unlinked Wallet",
      currency: "USD",
      current_balance: 1000
    )

    processor = CoinstatsAccount::Processor.new(unlinked_account)

    # Should not raise, just return early
    assert_nothing_raised do
      processor.process
    end
  end

  test "updates account balance from coinstats account" do
    @coinstats_account.update!(current_balance: 5000.50)

    processor = CoinstatsAccount::Processor.new(@coinstats_account)
    processor.process

    @account.reload
    assert_equal BigDecimal("5000.50"), @account.balance
    assert_equal BigDecimal("0"), @account.cash_balance
  end

  test "updates account currency from coinstats account" do
    @coinstats_account.update!(currency: "EUR")

    processor = CoinstatsAccount::Processor.new(@coinstats_account)
    processor.process

    @account.reload
    assert_equal "EUR", @account.currency
  end

  test "handles zero balance" do
    @coinstats_account.update!(current_balance: 0)

    processor = CoinstatsAccount::Processor.new(@coinstats_account)
    processor.process

    @account.reload
    assert_equal BigDecimal("0"), @account.balance
  end

  test "handles nil balance as zero" do
    @coinstats_account.update!(current_balance: nil)

    processor = CoinstatsAccount::Processor.new(@coinstats_account)
    processor.process

    @account.reload
    assert_equal BigDecimal("0"), @account.balance
  end

  test "processes transactions" do
    @coinstats_account.update!(raw_transactions_payload: [
      {
        type: "Received",
        date: "2025-01-15T10:00:00.000Z",
        coinData: { count: 1.0, symbol: "ETH", currentValue: 2000 },
        hash: { id: "0xabc123", explorerUrl: "https://etherscan.io/tx/0xabc123" }
      }
    ])

    processor = CoinstatsAccount::Processor.new(@coinstats_account)

    # Mock the transaction processor to verify it's called
    CoinstatsAccount::Transactions::Processor.any_instance
      .expects(:process)
      .returns({ success: true, total: 1, imported: 1, failed: 0, errors: [] })
      .once

    processor.process
  end

  test "continues processing when transaction processing fails" do
    @coinstats_account.update!(raw_transactions_payload: [
      { type: "Received", date: "2025-01-15T10:00:00.000Z" }
    ])

    processor = CoinstatsAccount::Processor.new(@coinstats_account)

    # Mock transaction processing to raise an error
    CoinstatsAccount::Transactions::Processor.any_instance
      .expects(:process)
      .raises(StandardError.new("Transaction processing error"))

    # Should not raise - error is caught and reported
    assert_nothing_raised do
      processor.process
    end

    # Balance should still be updated
    @account.reload
    assert_equal BigDecimal("2500"), @account.balance
  end

  test "normalizes currency codes" do
    @coinstats_account.update!(currency: "usd")

    processor = CoinstatsAccount::Processor.new(@coinstats_account)
    processor.process

    @account.reload
    assert_equal "USD", @account.currency
  end

  test "falls back to account currency when coinstats currency is nil" do
    @account.update!(currency: "GBP")
    # Use update_column to bypass validation
    @coinstats_account.update_column(:currency, "")

    processor = CoinstatsAccount::Processor.new(@coinstats_account)
    processor.process

    @account.reload
    # Empty currency falls through to account's existing currency
    assert_equal "GBP", @account.currency
  end

  # The transactions processor reports partial failure by returning `success: false` rather
  # than raising, so anchoring must honour that flag. Depository-backed because
  # Account::CurrentBalanceManager#ledger_explains? only does real work for :cash accounts.
  test "a discarded failed transaction import must not freeze the standing anchor as a reconciliation" do
    cash_account = @family.accounts.create!(
      accountable: Depository.new,
      name: "CoinStats-linked Checking",
      balance: 1000,
      cash_balance: 1000,
      currency: "USD"
    )

    cs_account = @coinstats_item.coinstats_accounts.create!(
      name: "Checking",
      currency: "USD",
      current_balance: 940
    )
    AccountProvider.create!(account: cash_account, provider: cs_account)

    anchor_date = 2.days.ago.to_date
    cash_account.entries.create!(
      date: anchor_date,
      name: Valuation.build_current_anchor_name("Depository"),
      amount: 1000,
      currency: "USD",
      entryable: Valuation.new(kind: "current_anchor")
    )

    CoinstatsAccount::HoldingsProcessor.any_instance.stubs(:process)

    # The 60.00 of activity that explains the drop from 1000 to 940 never lands: every
    # row failed, and the importer says so in its return value rather than by raising.
    CoinstatsAccount::Transactions::Processor.any_instance.stubs(:process).returns(
      { success: false, total: 3, imported: 0, failed: 3, errors: [] }
    )

    CoinstatsAccount::Processor.new(cs_account).process

    cash_account.reload

    assert_equal 0, cash_account.valuations.reconciliation.count,
      "an import that reported success: false must not freeze the standing anchor as a reconciliation waypoint"
    assert_equal anchor_date, cash_account.valuations.current_anchor.sole.entry.date,
      "the standing anchor must be left alone until a sync with a complete ledger can judge it"
  end

  test "raises error when account update fails" do
    # Make the account invalid by directly modifying a validation constraint
    Account.any_instance.stubs(:update!).raises(ActiveRecord::RecordInvalid.new(@account))

    processor = CoinstatsAccount::Processor.new(@coinstats_account)

    assert_raises(ActiveRecord::RecordInvalid) do
      processor.process
    end
  end
end
