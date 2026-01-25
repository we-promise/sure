require "test_helper"

class SnaptradeAccountProcessorTest < ActiveSupport::TestCase
  fixtures :families, :snaptrade_items, :snaptrade_accounts, :accounts, :securities

  setup do
    @family = families(:dylan_family)
    @snaptrade_item = snaptrade_items(:configured_item)
    @snaptrade_account = snaptrade_accounts(:fidelity_401k)

    # Create and link a Sure investment account
    @account = @family.accounts.create!(
      name: "Test Investment",
      balance: 50000,
      cash_balance: 1500,
      currency: "USD",
      accountable: Investment.new
    )
    @snaptrade_account.ensure_account_provider!(@account)
    @snaptrade_account.reload
  end

  # === HoldingsProcessor Tests ===

  test "holdings processor creates holdings from raw payload" do
    security = securities(:aapl)

    @snaptrade_account.update!(
      raw_holdings_payload: [
        {
          "symbol" => {
            "symbol" => { "symbol" => security.ticker, "description" => security.name }
          },
          "units" => "100.5",
          "price" => "150.25",
          "currency" => "USD"
        }
      ]
    )

    processor = SnaptradeAccount::HoldingsProcessor.new(@snaptrade_account)
    processor.process

    holding = @account.holdings.find_by(security: security)
    assert_not_nil holding
    assert_equal BigDecimal("100.5"), holding.qty
    assert_equal BigDecimal("150.25"), holding.price
  end

  test "holdings processor stores cost basis when available" do
    security = securities(:aapl)

    @snaptrade_account.update!(
      raw_holdings_payload: [
        {
          "symbol" => {
            "symbol" => { "symbol" => security.ticker, "description" => security.name }
          },
          "units" => "50",
          "price" => "175.00",
          "average_purchase_price" => "125.50",
          "currency" => "USD"
        }
      ]
    )

    processor = SnaptradeAccount::HoldingsProcessor.new(@snaptrade_account)
    processor.process

    holding = @account.holdings.find_by(security: security)
    assert_not_nil holding
    assert_equal BigDecimal("125.50"), holding.cost_basis
    assert_equal "provider", holding.cost_basis_source
  end

  test "holdings processor does not overwrite manual cost basis" do
    security = securities(:aapl)

    # Create holding with manual cost basis
    holding = @account.holdings.create!(
      security: security,
      date: Date.current,
      currency: "USD",
      qty: 50,
      price: 175.00,
      amount: 8750.00,
      cost_basis: 100.00,
      cost_basis_source: "manual"
    )

    @snaptrade_account.update!(
      raw_holdings_payload: [
        {
          "symbol" => {
            "symbol" => { "symbol" => security.ticker }
          },
          "units" => "50",
          "price" => "175.00",
          "average_purchase_price" => "125.50",
          "currency" => "USD"
        }
      ]
    )

    processor = SnaptradeAccount::HoldingsProcessor.new(@snaptrade_account)
    processor.process

    holding.reload
    assert_equal BigDecimal("100.00"), holding.cost_basis
    assert_equal "manual", holding.cost_basis_source
  end

  test "holdings processor skips entries without ticker" do
    @snaptrade_account.update!(
      raw_holdings_payload: [
        {
          "symbol" => { "symbol" => {} },  # Missing ticker
          "units" => "100",
          "price" => "50.00"
        }
      ]
    )

    processor = SnaptradeAccount::HoldingsProcessor.new(@snaptrade_account)

    assert_nothing_raised do
      processor.process
    end
    assert_equal 0, @account.holdings.count
  end

  # === ActivitiesProcessor Tests ===

  test "activities processor maps BUY type to Buy label" do
    security = securities(:aapl)

    @snaptrade_account.update!(
      raw_activities_payload: [
        {
          "id" => "activity_buy_1",
          "type" => "BUY",
          "symbol" => { "symbol" => security.ticker, "description" => security.name },
          "units" => "10",
          "price" => "150.00",
          "amount" => "1500.00",
          "settlement_date" => Date.current.to_s,
          "currency" => "USD"
        }
      ]
    )

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    result = processor.process

    assert_equal 1, result[:trades]
    trade_entry = @account.entries.find_by(external_id: "activity_buy_1")
    assert_not_nil trade_entry
    assert_equal "Buy", trade_entry.entryable.investment_activity_label
  end

  test "activities processor maps SELL type with negative quantity" do
    security = securities(:aapl)

    @snaptrade_account.update!(
      raw_activities_payload: [
        {
          "id" => "activity_sell_1",
          "type" => "SELL",
          "symbol" => { "symbol" => security.ticker },
          "units" => "5",
          "price" => "175.00",
          "amount" => "875.00",
          "settlement_date" => Date.current.to_s,
          "currency" => "USD"
        }
      ]
    )

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    result = processor.process

    assert_equal 1, result[:trades]
    trade_entry = @account.entries.find_by(external_id: "activity_sell_1")
    assert trade_entry.entryable.qty.negative?
    assert_equal "Sell", trade_entry.entryable.investment_activity_label
  end

  test "activities processor handles DIVIDEND as cash transaction" do
    @snaptrade_account.update!(
      raw_activities_payload: [
        {
          "id" => "activity_div_1",
          "type" => "DIVIDEND",
          "symbol" => { "symbol" => "AAPL" },
          "amount" => "25.50",
          "settlement_date" => Date.current.to_s,
          "currency" => "USD",
          "description" => "AAPL Dividend Payment"
        }
      ]
    )

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    result = processor.process

    assert_equal 1, result[:transactions]
    tx_entry = @account.entries.find_by(external_id: "activity_div_1")
    assert_not_nil tx_entry
    assert_equal "Transaction", tx_entry.entryable_type
    assert_equal "Dividend", tx_entry.entryable.investment_activity_label
  end

  test "activities processor normalizes withdrawal as negative amount" do
    @snaptrade_account.update!(
      raw_activities_payload: [
        {
          "id" => "activity_withdraw_1",
          "type" => "WITHDRAWAL",
          "amount" => "1000.00",  # Provider sends positive
          "settlement_date" => Date.current.to_s,
          "currency" => "USD"
        }
      ]
    )

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    result = processor.process

    assert_equal 1, result[:transactions]
    tx_entry = @account.entries.find_by(external_id: "activity_withdraw_1")
    assert tx_entry.amount.negative?
  end

  test "activities processor skips activities without external_id" do
    @snaptrade_account.update!(
      raw_activities_payload: [
        {
          "type" => "DIVIDEND",
          "amount" => "50.00"
          # Missing "id" field
        }
      ]
    )

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    result = processor.process

    assert_equal 0, result[:transactions]
    assert_equal 0, result[:trades]
  end

  test "activities processor handles unmapped types as Other" do
    @snaptrade_account.update!(
      raw_activities_payload: [
        {
          "id" => "activity_unknown_1",
          "type" => "UNKNOWN_TYPE_XYZ",
          "amount" => "100.00",
          "settlement_date" => Date.current.to_s,
          "currency" => "USD"
        }
      ]
    )

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    result = processor.process

    assert_equal 1, result[:transactions]
    tx_entry = @account.entries.find_by(external_id: "activity_unknown_1")
    assert_equal "Other", tx_entry.entryable.investment_activity_label
  end

  test "activities processor is idempotent with same external_id" do
    @snaptrade_account.update!(
      raw_activities_payload: [
        {
          "id" => "activity_idempotent_1",
          "type" => "DIVIDEND",
          "amount" => "75.00",
          "settlement_date" => Date.current.to_s,
          "currency" => "USD"
        }
      ]
    )

    processor = SnaptradeAccount::ActivitiesProcessor.new(@snaptrade_account)
    processor.process
    processor.process  # Process again

    entries = @account.entries.where(external_id: "activity_idempotent_1")
    assert_equal 1, entries.count
  end
end
