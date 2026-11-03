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

  # A crypto or spot-metal position carries no ISIN and no listing, and used to
  # be dropped for both reasons: counted among the positions the sync had
  # processed, missing from the account, and absent from the debug log.
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

  # Nothing quotes them, so the statement's mark price is the only price they
  # have; a fetch queued against them can only fail.
  test "an unlisted position's security is created offline and named" do
    @ibkr_account.update!(raw_holdings_payload: [ crypto_position ])

    IbkrAccount::HoldingsProcessor.new(@ibkr_account).process

    security = Security.find_by!(ticker: "CRYPTO:BTC")
    assert_predicate security, :offline?
    assert_equal "ibkr_unlisted", security.offline_reason
    assert_equal "BITCOIN", security.name
  end

  # "CRYPTO:" is the form every crypto integration here writes, so the IBKR
  # position joins the row they already use rather than splitting the asset in
  # two -- and the row's own pricing is left as that integration set it.
  test "an unlisted position reuses an existing security as it stands" do
    existing = Security.create!(
      ticker: "CRYPTO:BTC",
      name: "Bitcoin",
      exchange_operating_mic: "BNNC",
      price_provider: "binance_public"
    )
    @ibkr_account.update!(raw_holdings_payload: [ crypto_position ])

    assert_no_difference -> { Security.count } do
      IbkrAccount::HoldingsProcessor.new(@ibkr_account).process
    end

    assert_equal existing, holdings_by_ticker["CRYPTO:BTC"].security
    existing.reload
    assert_equal "binance_public", existing.price_provider
    assert_not_predicate existing, :offline?
  end

  # Only the ISIN requirement is lifted for them. A short position, or one with
  # no price to value it at, is no more importable than it was.
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

    # IBKR has no securityID or securityIDType to give for either of these, and
    # sends the attributes through empty. Rows as reported in #3946.
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
