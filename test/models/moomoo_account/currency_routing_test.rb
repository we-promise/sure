require "test_helper"

# A trading account split by currency: each currency's row imports its own
# positions, fills and cash log rows into its own Sure account.
class MoomooAccount::CurrencyRoutingTest < ActiveSupport::TestCase
  setup do
    travel_to Time.zone.parse("2026-10-24 12:00:00")

    @family = families(:dylan_family)
    @primary = moomoo_accounts(:main_account)
    @primary.update!(
      current_balance: 3225, cash_balance: 1300, last_seen_at: Time.current, last_positions_sync: Time.current,
      raw_positions_payload: positions, raw_fills_payload: fills, raw_orders_payload: orders, raw_cash_logs_payload: cash_logs
    )
    @sgd = create_account("moomoo SG (SGD)", "SGD")
    @primary.ensure_account_provider!(@sgd)

    Security::Resolver.stubs(:new).returns(stub(resolve: nil))
    Security::Resolver.stubs(:new).with("AAPL", exchange_operating_mic: nil, country_code: "US").returns(stub(resolve: securities(:aapl)))
    ExchangeRate.create!(from_currency: "USD", to_currency: "SGD", date: Date.current, rate: 1.3)
  end

  test "each currency's account takes only its own positions, trades and cash log rows" do
    usd = link_usd!

    process(@primary)
    process(usd_row)

    assert_equal [ [ "D05", "SGD" ] ], @sgd.holdings.includes(:security).map { |holding| [ holding.security.ticker, holding.currency ] }
    assert_equal [ [ "AAPL", "USD" ] ], usd.holdings.includes(:security).map { |holding| [ holding.security.ticker, holding.currency ] }

    assert_equal [ "moomoo_fill_1234567890123456_sg1" ], @sgd.entries.where(entryable_type: "Trade").pluck(:external_id)
    assert_equal [ "moomoo_fill_1234567890123456_us1" ], usd.entries.where(entryable_type: "Trade").pluck(:external_id)

    assert_equal [ "SGD" ], @sgd.entries.where(entryable_type: "Transaction").distinct.pluck(:currency)
    assert_equal [ "USD" ], usd.entries.where(entryable_type: "Transaction").distinct.pluck(:currency)
    assert_equal 2, @sgd.entries.where(entryable_type: "Transaction").count
    assert_equal 2, usd.entries.where(entryable_type: "Transaction").count

    @sgd.reload
    usd.reload
    assert_equal [ BigDecimal("3225"), BigDecimal("1300") ], [ @sgd.balance, @sgd.cash_balance ]
    assert_equal [ "USD", BigDecimal("2800"), BigDecimal("1000") ], [ usd.currency, usd.balance, usd.cash_balance ]
  end

  test "a currency exchange between the two accounts becomes a transfer from the currency sold" do
    usd = link_usd!

    process(@primary)
    process(usd_row)
    process(@primary)

    transfer = exchange_transfers.sole
    assert_equal [ @sgd, BigDecimal("1300"), "SGD" ], [ transfer.outflow_transaction.entry.account, transfer.outflow_transaction.entry.amount, transfer.outflow_transaction.entry.currency ]
    assert_equal [ usd, BigDecimal("-1000"), "USD" ], [ transfer.inflow_transaction.entry.account, transfer.inflow_transaction.entry.amount, transfer.inflow_transaction.entry.currency ]
    assert_equal %w[funds_movement funds_movement], [ transfer.outflow_transaction.reload.kind, transfer.inflow_transaction.reload.kind ]
  end

  test "an exchange the user unlinked stays unlinked" do
    link_usd!
    process(@primary)
    process(usd_row)
    exchange_transfers.sole.reject!

    process(@primary)
    process(usd_row)

    assert_not exchange_transfers.exists?
  end

  test "a currency whose account is not linked is not imported" do
    usd_row

    process(@primary)

    assert_equal [ "SGD" ], @sgd.holdings.distinct.pluck(:currency)
    assert_equal [ "SGD" ], @sgd.entries.where(source: "moomoo").distinct.pluck(:currency)
    assert_not exchange_transfers.exists?
  end

  test "a linked account that is split hands its other currency over to that currency's account" do
    # Before the split the one account took every currency.
    process(@primary)
    assert_equal %w[SGD USD], @sgd.entries.where(source: "moomoo").distinct.order(:currency).pluck(:currency)
    assert @sgd.holdings.where(currency: "USD").exists?
    dividend = @sgd.entries.find_by!(name: "Cash Dividend ACME")
    dividend.update!(user_modified: true, notes: "kept")

    # Split, with the USD account not set up yet: USD leaves the SGD account,
    # except the entry the user edited.
    usd_row
    process(MoomooAccount.find(@primary.id))
    @sgd.reload
    assert_equal [ dividend.id ], @sgd.entries.where(source: "moomoo", currency: "USD").pluck(:id)
    assert_not @sgd.holdings.where(currency: "USD").exists?
    assert_not @sgd.holdings.where(security: securities(:aapl)).exists?

    # Set up: the USD account takes the edited entry along with the rest.
    usd = link_usd!
    process(usd_row)
    assert_not @sgd.entries.where(source: "moomoo", currency: "USD").exists?
    assert_equal [ usd.id, true, "kept" ], [ dividend.reload.account_id, dividend.user_modified, dividend.notes ]
    assert_equal 1, usd.entries.where(name: "Cash Dividend ACME").count
    assert_equal [ "AAPL" ], usd.holdings.includes(:security).map { |holding| holding.security.ticker }
  end

  test "entries already in the other currency's account move there when it is linked" do
    process(@primary)
    usd = link_usd!

    process(usd_row)

    assert_equal [ "SGD" ], @sgd.entries.where(source: "moomoo").distinct.pluck(:currency)
    assert_equal [ "moomoo_fill_1234567890123456_us1" ], usd.entries.where(entryable_type: "Trade").pluck(:external_id)
    assert_equal 2, usd.entries.where(entryable_type: "Transaction").count
    assert_not @sgd.holdings.where(currency: "USD").exists?
  end

  test "each account works its past balances back from its own transactions" do
    # 2,600 SGD in, 1,300 SGD exchanged for 1,000 USD, then 180 USD of AAPL.
    @primary.update!(
      current_balance: 1300, cash_balance: 1300,
      raw_positions_payload: [ positions.last.merge("qty" => "1", "market_val" => "180.00") ],
      raw_fills_payload: [ fill("us1", "US.AAPL", "180") ], raw_cash_logs_payload: cash_logs.first(3)
    )
    usd = link_usd!
    usd_row.update!(current_balance: 1000, cash_balance: 820)

    process(@primary)
    process(usd_row)
    [ @sgd, usd ].each { |account| Balance::Materializer.new(account.reload, strategy: :reverse).materialize_balances }

    sgd_cash = @sgd.balances.where(currency: "SGD").pluck(:date, :cash_balance).to_h
    usd_cash = usd.balances.where(currency: "USD").pluck(:date, :cash_balance).to_h
    assert_equal [ 0, 2600, 1300, 1300 ], [ Date.new(2026, 9, 30), Date.new(2026, 10, 1), Date.new(2026, 10, 2), Date.current ].map { |date| sgd_cash.fetch(date, 0).to_d }
    assert_equal [ 0, 1000, 1000, 820 ], [ Date.new(2026, 10, 1), Date.new(2026, 10, 2), Date.new(2026, 10, 19), Date.current ].map { |date| usd_cash.fetch(date, 0).to_d }
    assert sgd_cash.values.none?(&:negative?)
    assert usd_cash.values.none?(&:negative?)
    assert_equal 1, exchange_transfers.count
  end

  test "a sync says which accounts are not imported until they are set up" do
    usd_row
    provider = Object.new
    def provider.method_missing(name, *_args, **_kwargs)
      case name
      when :get_accounts then [ { "account_id" => 1234567890123456, "security_firm" => "FUTUSG", "enable_market" => [ 6, 2 ], "account_card_number" => "1001234567893456" } ]
      when :get_positions then []
      when :get_funds then { "currency" => "SGD", "total_assets" => "0", "cash" => "0", "funds_assets" => "0", "sg_net_cash_power" => "0", "us_net_cash_power" => "0" }
      else { records: [], truncated: false }
      end
    end
    def provider.respond_to_missing?(*) = true
    item = @primary.moomoo_item
    item.update!(access_token_expires_at: 1.day.from_now)
    MoomooItem.any_instance.stubs(:moomoo_provider).returns(provider)
    sync = item.syncs.create!

    MoomooItem::Syncer.new(item).perform_sync(sync)

    details = sync.reload.sync_stats["data_quality_details"]
    assert_equal [
      "moomoo SG ••3456 (SGD cash) is not imported until you set up its account.",
      "moomoo SG ••3456 (USD cash) is not imported until you set up its account.",
      "moomoo SG ••3456 (USD stocks) is not imported until you set up its account."
    ], details.map { |detail| detail["message"] }.sort
  end

  private

    def process(moomoo_account)
      MoomooAccount::Processor.new(MoomooAccount.find(moomoo_account.id)).process
    end

    def exchange_transfers
      Transfer.where(outflow_transaction_id: Transaction.joins(:entry).where(entries: { account_id: @sgd.id }).select(:id))
    end

    def create_account(name, currency)
      @family.accounts.create!(name: name, balance: 0, cash_balance: 0, currency: currency, accountable: Investment.new)
    end

    def usd_row
      @usd_row ||= @primary.currency_accounts.create!(
        moomoo_item: @primary.moomoo_item, moomoo_account_id: @primary.moomoo_account_id, currency: "USD",
        name: "moomoo SG ••3456 (USD)", account_kind: "securities", security_firm: "FUTUSG",
        current_balance: 2800, cash_balance: 1000
      )
    end

    def link_usd!
      account = create_account("moomoo SG (USD)", "USD")
      usd_row.ensure_account_provider!(account)
      account
    end

    def positions
      [
        { "position_side" => "LONG", "code" => "SG.D05", "stock_name" => "DBS", "security_type" => "STOCK", "qty" => "50", "currency" => "SGD",
          "nominal_price" => "38.500", "cost_price_valid" => false, "market_val" => "1925.00" },
        { "position_side" => "LONG", "code" => "US.AAPL", "stock_name" => "Apple", "security_type" => "STOCK", "qty" => "10", "currency" => "USD",
          "nominal_price" => "180.000", "cost_price_valid" => false, "market_val" => "1800.00" }
      ]
    end

    def fills
      [ fill("sg1", "SG.D05", "38.5"), fill("us1", "US.AAPL", "180") ]
    end

    def fill(deal_id, code, price)
      micros = Provider::Moomoo.to_micros(Time.utc(2026, 10, 20, 15, 0))
      { "deal_id" => deal_id, "order_id" => "o-#{deal_id}", "trd_side" => "BUY", "code" => code, "stock_name" => code,
        "qty" => "1", "price" => price, "create_time" => micros, "updated_time" => micros, "status" => "OK" }
    end

    def orders
      {
        "o-sg1" => { "order_id" => "o-sg1", "currency" => "SGD", "security_type" => "STOCK" },
        "o-us1" => { "order_id" => "o-us1", "currency" => "USD", "security_type" => "STOCK" }
      }
    end

    def cash_logs
      [
        cash_log("Bank Transfer Deposits", "+2,600.00", "Balance: 2,600.00 SGD", "10/01/2026 09:00:00"),
        cash_log("Currency Exchange", "-1,300.00", "Balance: 1,300.00 SGD", "10/02/2026 10:00:00"),
        cash_log("Currency Exchange", "+1,000.00", "Balance: 1,000.00 USD", "10/02/2026 10:00:00"),
        cash_log("Cash Dividend", "+2.00", "Balance: 1,002.00 USD", "10/03/2026 10:00:00", symbol: "ACME")
      ]
    end

    def cash_log(name, change, balance, time, symbol: "")
      fields = { "transaction_name" => name, "created_time" => time, "cash_change" => change, "balance" => balance, "symbol" => symbol, "stock_name" => "" }
      fields.merge("digest" => Digest::SHA256.hexdigest(fields.values.join("|"))[0, 32])
    end
end
