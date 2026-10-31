require "test_helper"

class SharesightAccount::ProcessorCashTest < ActiveSupport::TestCase
  HOLDINGS = [
    { "id" => 1, "quantity" => 20.0, "value" => 2100.0, "instrument_price" => 105.0,
      "instrument" => { "code" => "VAS", "market_code" => "ASX", "currency_code" => "AUD" }, "instrument_currency" => { "code" => "AUD" } },
    { "id" => 2, "quantity" => 50.0, "value" => 2750.0, "instrument_price" => 55.0,
      "instrument" => { "code" => "BHP", "market_code" => "ASX", "currency_code" => "AUD" }, "instrument_currency" => { "code" => "AUD" } }
  ].freeze

  TRADES = [
    { "id" => 1, "transaction_type" => "BUY", "transaction_date" => "2026-09-01", "symbol" => "VAS", "market" => "ASX",
      "quantity" => 10, "price" => 100.0, "exchange_rate" => 1.0, "holding_id" => 1, "state" => "confirmed" },
    { "id" => 2, "transaction_type" => "BUY", "transaction_date" => "2026-09-10", "symbol" => "VAS", "market" => "ASX",
      "quantity" => 10, "price" => 110.0, "exchange_rate" => 1.0, "holding_id" => 1, "state" => "confirmed" }
  ].freeze

  PAYOUTS = [
    { "id" => 50, "symbol" => "VAS", "market" => "ASX", "paid_on" => "2026-09-20", "amount" => 30.0, "currency" => "AUD",
      "holding_id" => 1, "state" => "confirmed" }
  ].freeze

  setup do
    @family = families(:dylan_family)
    @item = @family.sharesight_items.create!(name: "Sharesight", client_id: "client-id", client_secret: "client-secret")
    @account = @family.accounts.create!(name: "CMC Invest", balance: 0, currency: "AUD", accountable: Investment.new)
    @sharesight_account = @item.sharesight_accounts.create!(
      name: "Shares", sharesight_account_id: "42", currency: "AUD", current_balance: 4850, cash_balance: 0,
      raw_holdings_payload: HOLDINGS, raw_trades_payload: TRADES, raw_payouts_payload: PAYOUTS
    )
    @sharesight_account.ensure_account_provider!(@account)
    %w[VAS BHP].each { |ticker| Security.find_or_create_by!(ticker: ticker, exchange_operating_mic: "XASX") }
  end

  test "observed broker cash is rolled forward through what's been booked since" do
    @sharesight_account.update!(cash_anchor_amount: 2000, cash_anchor_on: Date.new(2026, 9, 5))

    process

    # 2000 - the 1100 buy on 10 Sep + the 30 dividend on 20 Sep.
    @account.reload
    assert_equal [ BigDecimal("930"), BigDecimal("5780") ], [ @account.cash_balance, @account.balance ]
  end

  test "a foreign trade after the anchor is paid from the portfolio's cash" do
    us_buy = { "id" => 3, "transaction_type" => "BUY", "transaction_date" => "2026-09-15", "symbol" => "AAPL", "market" => "NASDAQ",
               "quantity" => 10, "price" => 100.0, "exchange_rate" => 0.5, "holding_id" => 3, "state" => "confirmed" }
    us_holding = { "id" => 3, "quantity" => 10.0, "value" => 2000.0, "instrument_price" => 100.0,
                   "instrument" => { "code" => "AAPL", "market_code" => "NASDAQ", "currency_code" => "USD" }, "instrument_currency" => { "code" => "USD" } }
    @sharesight_account.update!(
      raw_trades_payload: TRADES + [ us_buy ], raw_holdings_payload: HOLDINGS + [ us_holding ], current_balance: 6850,
      cash_anchor_amount: 5000, cash_anchor_on: Date.new(2026, 9, 5)
    )

    process

    # US$1,000 at 0.5 USD per AUD is A$2,000: 5000 - 1100 + 30 - 2000.
    assert_equal BigDecimal("1930"), @account.reload.cash_balance
  end

  test "a portfolio settled elsewhere is shares only" do
    @sharesight_account.update!(cash_mode: "untracked", cash_anchor_amount: 2000, cash_anchor_on: Date.new(2026, 9, 5))

    process

    @account.reload
    assert_equal [ BigDecimal("0"), BigDecimal("4850") ], [ @account.cash_balance, @account.balance ]
  end

  test "units the trades don't account for are reported" do
    notices = process[:notices]

    assert_equal [ I18n.t("sharesight_accounts.notices.units_drift", account: "CMC Invest", ticker: "BHP", held: "50.0", traded: "0.0") ],
                 notices.map { |notice| notice[:message] }
  end

  test "limited holdings aren't compared" do
    hidden = { "id" => 9, "quantity" => 5.0, "limited" => true, "instrument" => { "code" => "HIDDEN", "market_code" => "ASX" } }
    hidden_buy = { "id" => 9, "transaction_type" => "BUY", "transaction_date" => "2026-09-12", "symbol" => "HIDDEN", "market" => "ASX",
                   "quantity" => 3, "price" => 10.0, "exchange_rate" => 1.0, "holding_id" => 9, "state" => "confirmed" }
    Security.find_or_create_by!(ticker: "HIDDEN", exchange_operating_mic: "XASX")
    @sharesight_account.update!(raw_holdings_payload: HOLDINGS + [ hidden ], raw_trades_payload: TRADES + [ hidden_buy ])

    notices = process[:notices].map { |notice| notice[:message] }

    assert notices.none? { |message| message.include?("HIDDEN") }
  end

  test "units that match to 8 decimal places aren't reported" do
    noisy = HOLDINGS.map { |holding| holding.dig("instrument", "code") == "VAS" ? holding.merge("quantity" => 20.000000000000004) : holding }
    @sharesight_account.update!(raw_holdings_payload: noisy)

    notices = process[:notices].map { |notice| notice[:message] }

    assert notices.none? { |message| message.include?("VAS") }
  end

  test "a sync start date leaves older activity out and removes what was imported" do
    process
    assert @account.entries.find_by(external_id: "sharesight_trade_1")

    @sharesight_account.update!(sync_start_date: Date.new(2026, 9, 5))
    notices = process[:notices]

    assert_nil @account.entries.find_by(external_id: "sharesight_trade_1")
    assert @account.entries.find_by(external_id: "sharesight_trade_2")
    assert_empty notices, "units can't reconcile without the older trades"
  end

  test "the sync summary shows the notices" do
    sync = @item.syncs.create!
    @item.stubs(:import_latest_data)
    SharesightItem.any_instance.stubs(:schedule_account_syncs)

    SharesightItem::Syncer.new(@item).perform_sync(sync)

    details = sync.reload.sync_stats["data_quality_details"]
    assert_equal 1, sync.sync_stats["data_warnings"]
    assert_match "BHP", details.first["message"]
  end

  private

    def process
      SharesightAccount::Processor.new(@sharesight_account.reload).process
    end
end
