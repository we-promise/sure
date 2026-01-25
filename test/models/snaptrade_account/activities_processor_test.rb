require "test_helper"

class SnaptradeAccount::ActivitiesProcessorTest < ActiveSupport::TestCase
  include SecuritiesTestHelper

  setup do
    @family = families(:dylan_family)
    @snaptrade_item = snaptrade_items(:configured_item)
    @snaptrade_account = snaptrade_accounts(:fidelity_401k)

    # Create a linked Sure account for the SnapTrade account
    @account = @family.accounts.create!(
      name: "Test Investment",
      balance: 50000,
      cash_balance: 1000,
      currency: "USD",
      accountable: Investment.new
    )

    # Link the SnapTrade account to the Sure account
    @snaptrade_account.ensure_account_provider!(@account)
    @snaptrade_account.reload
  end

  test "processes buy trade activity" do
    @snaptrade_account.update!(raw_activities_payload: [
      build_trade_activity(
        id: "trade_001",
        type: "BUY",
        symbol: "AAPL",
        units: 10,
        price: 150.00,
        settlement_date: Date.current.to_s
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    # Verify a trade was created (external_id is on entry, not trade)
    entry = @account.entries.find_by(external_id: "trade_001", source: "snaptrade")
    assert_not_nil entry, "Entry should be created"
    assert entry.entryable.is_a?(Trade), "Entry should be a Trade"

    trade = entry.entryable
    assert_equal 10, trade.qty
    assert_equal 150.00, trade.price.to_f
    assert_equal "Buy", trade.investment_activity_label
  end

  test "processes sell trade activity with negative quantity" do
    @snaptrade_account.update!(raw_activities_payload: [
      build_trade_activity(
        id: "trade_002",
        type: "SELL",
        symbol: "AAPL",
        units: 5,
        price: 160.00,
        settlement_date: Date.current.to_s
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    entry = @account.entries.find_by(external_id: "trade_002", source: "snaptrade")
    assert_not_nil entry
    trade = entry.entryable
    assert_equal(-5, trade.qty)  # Sell should be negative
    assert_equal "Sell", trade.investment_activity_label
  end

  test "processes dividend cash activity" do
    @snaptrade_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "div_001",
        type: "DIVIDEND",
        amount: 25.50,
        settlement_date: Date.current.to_s,
        symbol: "VTI"
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    entry = @account.entries.find_by(external_id: "div_001", source: "snaptrade")
    assert_not_nil entry, "Entry should be created"
    assert entry.entryable.is_a?(Transaction), "Entry should be a Transaction"

    transaction = entry.entryable
    assert_equal "Dividend", transaction.investment_activity_label
  end

  test "processes contribution with positive amount" do
    @snaptrade_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "contrib_001",
        type: "CONTRIBUTION",
        amount: 500.00,
        settlement_date: Date.current.to_s
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    entry = @account.entries.find_by(external_id: "contrib_001", source: "snaptrade")
    assert_not_nil entry
    # Amount is on entry, not transaction
    assert_equal 500.00, entry.amount.to_f  # Positive for contributions
    assert_equal "Contribution", entry.entryable.investment_activity_label
  end

  test "processes withdrawal with negative amount" do
    @snaptrade_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "withdraw_001",
        type: "WITHDRAWAL",
        amount: 200.00,
        settlement_date: Date.current.to_s
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    entry = @account.entries.find_by(external_id: "withdraw_001", source: "snaptrade")
    assert_not_nil entry
    assert_equal(-200.00, entry.amount.to_f)  # Negative for withdrawals
    assert_equal "Withdrawal", entry.entryable.investment_activity_label
  end

  test "maps all known activity types correctly" do
    type_mappings = {
      "BUY" => "Buy",
      "SELL" => "Sell",
      "DIVIDEND" => "Dividend",
      "DIV" => "Dividend",
      "CONTRIBUTION" => "Contribution",
      "WITHDRAWAL" => "Withdrawal",
      "TRANSFER_IN" => "Transfer",
      "TRANSFER_OUT" => "Transfer",
      "INTEREST" => "Interest",
      "FEE" => "Fee",
      "TAX" => "Fee",
      "REI" => "Reinvestment",
      "REINVEST" => "Reinvestment",
      "CASH" => "Contribution",
      "CORP_ACTION" => "Other",
      "SPLIT_REVERSE" => "Other"
    }

    type_mappings.each do |snaptrade_type, expected_label|
      actual = SnaptradeAccount::ActivitiesProcessor::SNAPTRADE_TYPE_TO_LABEL[snaptrade_type]
      assert_equal expected_label, actual, "Type #{snaptrade_type} should map to #{expected_label}"
    end
  end

  test "logs unmapped activity types" do
    @snaptrade_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: "unknown_001",
        type: "SOME_NEW_TYPE",
        amount: 100.00,
        settlement_date: Date.current.to_s
      )
    ])

    # Capture log output
    log_output = StringIO.new
    old_logger = Rails.logger
    Rails.logger = Logger.new(log_output)

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    Rails.logger = old_logger

    assert_includes log_output.string, "Unmapped activity type 'SOME_NEW_TYPE'"
  end

  test "skips activities without external_id" do
    @snaptrade_account.update!(raw_activities_payload: [
      build_cash_activity(
        id: nil,
        type: "DIVIDEND",
        amount: 50.00,
        settlement_date: Date.current.to_s
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    # No entry should be created with snaptrade source
    assert_equal 0, @account.entries.where(source: "snaptrade").count
  end

  test "skips processing when no linked account" do
    # Remove the account provider link
    @snaptrade_account.account_provider&.destroy
    @snaptrade_account.reload

    @snaptrade_account.update!(raw_activities_payload: [
      build_trade_activity(
        id: "trade_orphan",
        type: "BUY",
        symbol: "AAPL",
        units: 10,
        price: 150.00,
        settlement_date: Date.current.to_s
      )
    ])

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process

    # No entries should be created with this external_id
    assert_equal 0, Entry.where(external_id: "trade_orphan").count
  end

  private

    def build_trade_activity(id:, type:, symbol:, units:, price:, settlement_date:)
      {
        "id" => id,
        "type" => type,
        "symbol" => {
          "symbol" => symbol,
          "description" => "#{symbol} Inc"
        },
        "units" => units,
        "price" => price,
        "settlement_date" => settlement_date,
        "currency" => { "code" => "USD" }
      }
    end

    def build_cash_activity(id:, type:, amount:, settlement_date:, symbol: nil)
      activity = {
        "id" => id,
        "type" => type,
        "amount" => amount,
        "settlement_date" => settlement_date,
        "currency" => { "code" => "USD" }
      }

      if symbol
        activity["symbol"] = {
          "symbol" => symbol,
          "description" => "#{symbol} Fund"
        }
      end

      activity
    end
end
