require "test_helper"

class SimplefinAccount::Transactions::TradeAutofillTest < ActiveSupport::TestCase
  setup do
    @original_flag = Rails.configuration.x.simplefin.trade_autofill_enabled
    Rails.configuration.x.simplefin.trade_autofill_enabled = true
  end

  teardown do
    Rails.configuration.x.simplefin.trade_autofill_enabled = @original_flag
  end

  test "parses a buy description into decimal quantity, company, and price" do
    parsed = SimplefinAccount::Transactions::TradeAutofill.parse("Buy 2.5 shares of Vanguard Total Stock Market ETF for $80.12 each")

    assert_equal "Vanguard Total Stock Market ETF", parsed[:company]
    assert_equal BigDecimal("2.5"), parsed[:quantity]
    assert_equal BigDecimal("80.12"), parsed[:price]
  end

  test "only reconciles when quantity times price matches the transaction amount" do
    parsed = { quantity: BigDecimal("2"), price: BigDecimal("50") }

    assert SimplefinAccount::Transactions::TradeAutofill.amount_matches?(parsed, BigDecimal("100.01"))
    refute SimplefinAccount::Transactions::TradeAutofill.amount_matches?(parsed, BigDecimal("100.03"))
  end

  test "feature flag is disabled when configuration is false" do
    Rails.configuration.x.simplefin.trade_autofill_enabled = false

    refute SimplefinAccount::Transactions::TradeAutofill.enabled?
  end

  test "feature flag prevents conversion" do
    Rails.configuration.x.simplefin.trade_autofill_enabled = false
    entry = Minitest::Mock.new

    SimplefinAccount::Transactions::TradeAutofill.convert(entry)

    entry.verify
  end

  test "converts a matching SimpleFIN investment transaction to an existing security trade" do
    family = families(:dylan_family)
    account = Account.create!(
      family: family,
      name: "Brokerage",
      currency: "USD",
      balance: 1000,
      accountable: Investment.new(subtype: :brokerage)
    )
    security = Security.create!(ticker: "VTI", name: "Vanguard Total Stock Market ETF", kind: "standard")
    entry = account.entries.create!(
      external_id: "simplefin_trade_1",
      source: "simplefin",
      name: "Buy 2 shares of VTI for $100 each",
      date: Date.current,
      amount: 200,
      currency: "USD",
      entryable: Transaction.new(kind: "standard")
    )

    SimplefinAccount::Transactions::TradeAutofill.convert(entry)

    assert entry.reload.excluded?
    trade_entry = account.entries.find_by(source: "simplefin_trade_autofill")
    assert trade_entry
    assert_equal security, trade_entry.trade.security
    assert_equal BigDecimal("2"), trade_entry.trade.qty
    assert_equal BigDecimal("100"), trade_entry.trade.price
    assert_equal 1, account.entries.where(source: "simplefin_trade_autofill").count

    SimplefinAccount::Transactions::TradeAutofill.convert(entry.reload)
    assert_equal 1, account.entries.where(source: "simplefin_trade_autofill").count
  end
end
