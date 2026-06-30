# frozen_string_literal: true

require "test_helper"

class QuestradeAccount::ProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @questrade_item = @family.questrade_items.create!(name: "Test", refresh_token: "dummy-token")
    @questrade_account = @questrade_item.questrade_accounts.create!(
      questrade_account_id: "53999999",
      name: "TFSA (53999999)",
      currency: "CAD",
      current_balance: 1500
    )
    @account = @family.accounts.create!(
      name: "TFSA",
      balance: 0,
      currency: "CAD",
      accountable: Investment.new
    )
    @questrade_account.ensure_account_provider!(@account)
    @questrade_account.reload
  end

  # ---- Processor ----------------------------------------------------------

  test "processor anchors the account balance from the questrade total" do
    @questrade_account.update!(current_balance: 2500, cash_balance: 500)

    QuestradeAccount::Processor.new(@questrade_account).process

    assert_equal 2500, @account.reload.balance.to_d
  end

  test "processor is a no-op when the provider account is not linked" do
    @questrade_account.account_provider.destroy
    @questrade_account.reload

    assert_nothing_raised { QuestradeAccount::Processor.new(@questrade_account).process }
  end

  # ---- HoldingsProcessor --------------------------------------------------

  test "holdings processor imports positions as holdings" do
    @questrade_account.update!(raw_holdings_payload: [
      { "symbol" => "AAPL", "symbolId" => 8049, "openQuantity" => 10,
        "currentPrice" => 150.0, "currentMarketValue" => 1500.0,
        "averageEntryPrice" => 140.0, "currency" => "USD" }
    ])

    QuestradeAccount::HoldingsProcessor.new(@questrade_account).process

    security = Security.find_by(ticker: "AAPL")
    assert_not_nil security
    assert @account.reload.holdings.where(security: security).exists?
  end

  test "holdings processor skips positions with a blank symbol" do
    @questrade_account.update!(raw_holdings_payload: [
      { "symbol" => "", "openQuantity" => 10, "currentPrice" => 100.0 }
    ])

    assert_nothing_raised { QuestradeAccount::HoldingsProcessor.new(@questrade_account).process }
    assert_empty @account.reload.holdings
  end

  # ---- ActivitiesProcessor ------------------------------------------------

  test "activities processor imports a Buy trade" do
    @questrade_account.update!(raw_activities_payload: [
      { "type" => "Trades", "action" => "Buy", "symbol" => "AAPL", "symbolId" => 8049,
        "quantity" => 10, "price" => 150.0, "netAmount" => -1500.0,
        "transactionDate" => "2026-06-01", "tradeDate" => "2026-06-01",
        "currency" => "USD", "description" => "Apple Inc" }
    ])

    result = QuestradeAccount::ActivitiesProcessor.new(@questrade_account).process

    assert_equal 1, result[:trades]
    entry = @account.reload.entries.find_by(source: "questrade")
    assert_not_nil entry
    assert entry.entryable.is_a?(Trade)
  end

  test "activities processor skips entries with a blank type" do
    @questrade_account.update!(raw_activities_payload: [
      { "type" => "", "symbol" => "AAPL", "quantity" => 10, "price" => 100.0 }
    ])

    QuestradeAccount::ActivitiesProcessor.new(@questrade_account).process

    assert_equal 0, @account.reload.entries.where(source: "questrade").count
  end
end
