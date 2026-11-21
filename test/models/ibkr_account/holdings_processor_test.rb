require "test_helper"

class IbkrAccount::HoldingsProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(
      name: "IBKR Brokerage",
      balance: 0,
      cash_balance: 0,
      currency: "USD",
      accountable: Investment.new(subtype: "brokerage")
    )
    @ibkr_account = @family.ibkr_items.create!(
      name: "IBKR",
      query_id: "QUERY123",
      token: "TOKEN123"
    ).ibkr_accounts.create!(
      name: "Main",
      ibkr_account_id: "U1234567",
      currency: "USD",
      report_date: Date.new(2026, 5, 8)
    )
    @ibkr_account.ensure_account_provider!(@account)
  end

  test "imports crypto and commodity positions alongside stocks" do
    @ibkr_account.update!(raw_holdings_payload: [ stock_position, crypto_position, metal_position ])

    IbkrAccount::HoldingsProcessor.new(@ibkr_account).process

    assert_equal %w[AAPL CMDTY:USGOLD CRYPTO:BTC], holdings_by_ticker.keys.sort

    bitcoin = holdings_by_ticker["CRYPTO:BTC"]
    assert_equal 0.5, bitcoin.qty
    assert_equal 60_000, bitcoin.price
    assert_equal 30_000, bitcoin.amount

    gold = holdings_by_ticker["CMDTY:USGOLD"]
    assert_equal 2, gold.qty
    assert_equal 4_000, gold.amount
  end

  # The crypto namespace is quotable, so the row stays eligible for the price
  # history every other integration sharing it expects. A spot metal is quoted
  # by nobody, and offline keeps the daily fetch off it.
  test "crypto is bound to the crypto price provider and a commodity is offline" do
    @ibkr_account.update!(raw_holdings_payload: [ crypto_position, metal_position ])

    IbkrAccount::HoldingsProcessor.new(@ibkr_account).process

    bitcoin = Security.find_by!(ticker: "CRYPTO:BTC")
    assert_not_predicate bitcoin, :offline?
    assert_equal "binance_public", bitcoin.price_provider
    assert_equal Provider::BinancePublic::BINANCE_MIC, bitcoin.exchange_operating_mic
    assert_equal "BITCOIN", bitcoin.name

    gold = Security.find_by!(ticker: "CMDTY:USGOLD")
    assert_predicate gold, :offline?
    assert_equal "ibkr_commodity", gold.offline_reason
    assert_equal "Gold (London Fix) USD/oz", gold.name
  end

  # Securities are global: whichever flow created the row chose its pricing.
  test "an unlisted position reuses an existing security as it stands" do
    existing = Security.create!(
      ticker: "CRYPTO:BTC",
      name: "Bitcoin",
      exchange_operating_mic: "XCBS",
      price_provider: "twelve_data"
    )
    @ibkr_account.update!(raw_holdings_payload: [ crypto_position ])

    assert_no_difference -> { Security.count } do
      IbkrAccount::HoldingsProcessor.new(@ibkr_account).process
    end

    assert_equal existing, holdings_by_ticker["CRYPTO:BTC"].security
    existing.reload
    assert_equal "twelve_data", existing.price_provider
    assert_equal "XCBS", existing.exchange_operating_mic
  end

  # A holding is keyed on (security, date, currency), so two groups for one
  # security would overwrite each other rather than sum.
  test "one symbol reported under two conids sums into a single holding" do
    @ibkr_account.update!(raw_holdings_payload: [
      crypto_position,
      crypto_position.merge("conid" => "641027225", "position" => "1.5", "cost_basis_price" => "50000.00")
    ])

    bitcoin = process_and_find("CRYPTO:BTC")

    assert_equal 1, @account.holdings.count
    assert_equal 2, bitcoin.qty
    assert_equal 120_000, bitcoin.amount
  end

  # A group holds every lot of one asset, and IBKR marks each conid on its own.
  test "each lot is valued at its own mark price" do
    @ibkr_account.update!(raw_holdings_payload: [
      crypto_position,
      crypto_position.merge("conid" => "641027225", "position" => "1.5", "mark_price" => "40000.00")
    ])

    bitcoin = process_and_find("CRYPTO:BTC")

    assert_equal 2, bitcoin.qty
    assert_equal 90_000, bitcoin.amount, "0.5 at 60,000 plus 1.5 at 40,000"
    assert_equal 45_000, bitcoin.price, "the weighted average the amount implies"
  end

  # supported_position? only asks that mark_price be present, and a group's
  # other lots carry it past that check, so an unparseable one would otherwise
  # add its quantity to the group at no value.
  test "a lot with an unusable mark price does not inflate its group's quantity" do
    @ibkr_account.update!(raw_holdings_payload: [
      crypto_position,
      crypto_position.merge("mark_price" => "N/A", "position" => "9"),
      crypto_position.merge("mark_price" => "", "position" => "7")
    ])

    bitcoin = process_and_find("CRYPTO:BTC")

    assert_equal 0.5, bitcoin.qty
    assert_equal 30_000, bitcoin.amount
  end

  # A group that cannot be imported must not leave a security behind with no
  # holding on it.
  test "an unparseable mark price creates no security" do
    @ibkr_account.update!(raw_holdings_payload: [ crypto_position.merge("mark_price" => "N/A") ])

    assert_no_difference -> { Security.count } do
      IbkrAccount::HoldingsProcessor.new(@ibkr_account).process
    end

    assert_empty @account.holdings
  end

  # Only the securityID requirement is lifted for an unlisted position.
  test "unsupported categories and incomplete rows are still skipped" do
    @ibkr_account.update!(raw_holdings_payload: [
      crypto_position.merge("asset_category" => "OPT"),
      crypto_position.merge("symbol" => "ETH", "conid" => "99", "side" => "Short"),
      crypto_position.merge("symbol" => "SOL", "conid" => "98", "mark_price" => "")
    ])

    IbkrAccount::HoldingsProcessor.new(@ibkr_account).process

    assert_empty @account.holdings
  end

  private

    def process_and_find(ticker)
      IbkrAccount::HoldingsProcessor.new(@ibkr_account).process
      holdings_by_ticker.fetch(ticker)
    end

    def holdings_by_ticker
      @account.holdings.includes(:security).index_by { |holding| holding.security.ticker }
    end

    def stock_position
      {
        "asset_category" => "STK",
        "conid" => "265598",
        "security_id" => "US0378331005",
        "security_id_type" => "ISIN",
        "symbol" => "AAPL",
        "description" => "APPLE INC",
        "position" => "10",
        "mark_price" => "150.00",
        "currency" => "USD",
        "fx_rate_to_base" => "1",
        "cost_basis_price" => "125.50",
        "report_date" => "2026-05-08",
        "side" => "Long"
      }
    end

    # IBKR sends securityID and securityIDType through empty for both of these.
    # Rows as reported in #3946.
    def crypto_position
      {
        "asset_category" => "CRYPTO",
        "conid" => "530091182",
        "security_id" => "",
        "security_id_type" => "",
        "symbol" => "BTC",
        "description" => "BITCOIN",
        "position" => "0.5",
        "mark_price" => "60000.00",
        "currency" => "USD",
        "fx_rate_to_base" => "1",
        "cost_basis_price" => "40000.00",
        "report_date" => "2026-05-08",
        "side" => "Long"
      }
    end

    def metal_position
      {
        "asset_category" => "CMDTY",
        "conid" => "474636065",
        "security_id" => "",
        "security_id_type" => "",
        "symbol" => "USGOLD",
        "description" => "Gold (London Fix) USD/oz",
        "position" => "2",
        "mark_price" => "2000.00",
        "currency" => "USD",
        "fx_rate_to_base" => "1",
        "cost_basis_price" => "1800.00",
        "report_date" => "2026-05-08",
        "side" => "Long"
      }
    end
end
