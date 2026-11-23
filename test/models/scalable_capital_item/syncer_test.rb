require "test_helper"

class ScalableCapitalItem::SyncerTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = @family.scalable_capital_items.create!(portfolio_id: "portfolio", savings_id: "savings")
    ScalableCapitalItem.stubs(:configured_family_id).returns(@family.id)
    @client = mock
    Security.stubs(:search_provider).returns([])
    travel_to Time.utc(2026, 11, 21, 12)
  end

  test "imports separate cash accounts, trades, paired settlements and exact ticker cost basis" do
    isin = "IE00B4L5Y983"
    correct = Security.new(ticker: "EUNL", name: "Example ETF", search_isin: isin, search_currency: "EUR",
                           country_code: "DE", exchange_operating_mic: "XETR")
    unrelated = Security.new(ticker: "WRONG", search_isin: "US0378331005", search_currency: "EUR",
                             country_code: "DE", exchange_operating_mic: "XETR")
    Security.expects(:search_provider).with(isin, country_code: "DE", technical_failure: kind_of(Proc)).once.returns([ unrelated, correct ])

    stub_snapshot
    run_sync
    checkpoint = @item.reload.broker_synced_through
    travel 1.day
    stub_snapshot
    @client.expects(:trade).never
    @client.expects(:broker_transactions)
      .with("portfolio", since: checkpoint - 1.second, before: Time.current)
      .yields(broker({}), broker_events + [ cash_event("new-deposit", "DEPOSIT", amount: "25", at: checkpoint) ])
    run_sync

    broker = @item.scalable_capital_accounts.brokerage.first.account
    cash = @item.scalable_capital_accounts.cash.first.account
    savings = @item.scalable_capital_accounts.savings.first.account
    assert_equal 3, @item.accounts.count
    assert_equal "Investment", broker.accountable_type
    assert_equal "Depository", cash.accountable_type
    assert_equal "Depository", savings.accountable_type
    assert_equal 1000.to_d, broker.reload.balance
    assert_equal 0.to_d, broker.cash_balance
    assert_equal 255.25.to_d, cash.reload.balance
    assert_equal 50.to_d, savings.reload.balance
    assert_equal Time.current, @item.reload.broker_synced_through
    assert_equal Time.current, @item.savings_synced_through
    assert_equal "person", @item.broker_account_id

    holding = broker.holdings.where.not(account_provider_id: nil).order(:date).last
    assert_equal "EUNL", holding.ticker
    assert_equal 2.5.to_d, holding.qty
    assert_equal 1000.to_d, holding.amount
    assert_equal 110.to_d, holding.cost_basis
    assert_equal holding.security_id, @item.security_ids.fetch(isin)

    trades = broker.entries.where(entryable_type: "Trade").order(:external_id)
    assert_equal 2, trades.size
    assert_equal [ 301.to_d, -98.to_d ], trades.map(&:amount)
    assert_equal [ 2.5.to_d, -1.to_d ], trades.map { |entry| entry.entryable.qty }
    assert_equal [ 1.to_d, 2.to_d ], trades.map { |entry| entry.entryable.fee }
    assert_equal [ holding.security_id ], trades.map { |entry| entry.entryable.security_id }.uniq
    assert_equal 0.to_d, broker.entries.where(source: "scalable_capital").sum(:amount)

    %w[buy sell].each do |id|
      cash_leg = cash.entries.find_by!(external_id: "settlement:#{id}")
      investment_leg = broker.entries.find_by!(external_id: "settlement:#{id}")
      assert_equal(-investment_leg.amount, cash_leg.amount)
      assert_equal investment_leg.entryable.transfer, cash_leg.entryable.transfer
      assert_predicate cash_leg.entryable.transfer, :confirmed?
      refute_predicate cash_leg.entryable.transfer, :investment_contribution?
    end

    assert_equal 1, cash.entries.where(entryable_type: "Transaction", external_id: "dividend").count
    assert_equal(-2.5.to_d, cash.entries.find_by!(external_id: "dividend").amount)
    assert_equal(-25.to_d, cash.entries.find_by!(external_id: "new-deposit").amount)
    assert_equal 0.99.to_d, cash.entries.find_by!(external_id: "fee").amount
    assert_equal(-1.25.to_d, savings.entries.find_by!(external_id: "interest").amount)
    assert_equal(-20.to_d, cash.entries.find_by!(external_id: "cash-transfer-in").amount)
    outgoing = savings.entries.find_by!(external_id: "cash-transfer-out")
    assert_equal 20.to_d, outgoing.amount
    @family.auto_match_transfers!(account: savings)
    assert_equal outgoing.entryable.transfer, cash.entries.find_by!(external_id: "cash-transfer-in").entryable.transfer
    assert_not_nil outgoing.entryable.transfer
    assert_nil cash.entries.find_by(external_id: "pending")
    assert_nil cash.entries.find_by(external_id: "cancelled")
  end

  test "imports a completed trade with final fill status" do
    stub_snapshot
    detail = trade("buy", "BUY", "2.5", "120", "301")
    detail.fetch("security_trade")["status"] = "FINAL_FILL"
    @client.stubs(:trade).with("portfolio", "buy").returns(broker(detail))
    run_sync

    account = @item.scalable_capital_accounts.brokerage.sole.account
    buy = account.entries.trades.find_by!(external_id: "buy")
    assert_equal 301.to_d, buy.amount
    assert_equal 1.to_d, buy.entryable.fee
    assert_equal Time.current, @item.reload.broker_synced_through
  end

  test "preserves net sale proceeds and fees when a tax credit raises the settlement above gross" do
    stub_snapshot
    detail = trade("sell", "SELL", "3", "34", "105")
    detail.fetch("security_trade")["trade_transaction_amounts"] = {
      "market_valuation" => "102", "transaction_fee" => "0.75", "venue_fee" => "0.25", "tax_amount" => "-4"
    }
    @client.stubs(:trade).with("portfolio", "sell").returns(broker(detail))
    run_sync

    accounts = @item.scalable_capital_accounts
    sale = accounts.brokerage.sole.account.entries.trades.find_by!(external_id: "sell")
    assert_equal(-105.to_d, sale.amount)
    assert_equal 34.to_d, sale.entryable.price
    assert_equal 1.to_d, sale.entryable.fee
    assert_equal(-105.to_d, accounts.cash.sole.account.entries.find_by!(external_id: "settlement:sell").amount)
  end

  test "books a trade on its execution date even if its final status changes later" do
    stub_snapshot
    detail = trade("buy", "BUY", "2.5", "120", "301")
    detail["history"] = [
      { "state" => "SETTLED", "timestamp" => "2026-11-19T23:30:00Z" },
      { "state" => "FILLED", "timestamp" => "2026-11-19T18:00:00Z" },
      { "state" => "PARTIAL_FILL", "timestamp" => "2026-11-19T17:00:00Z" }
    ]
    @client.stubs(:trade).with("portfolio", "buy").returns(broker(detail))
    run_sync

    account = @item.scalable_capital_accounts.brokerage.sole.account
    buy = account.entries.trades.find_by!(external_id: "buy")
    assert_equal Date.new(2026, 11, 19), buy.date
    assert_equal Time.utc(2026, 11, 19, 18), buy.occurred_at
    assert_equal Time.current, buy.created_at
  end

  test "uses execution order for same-day FIFO even when an earlier buy settles in a later sync" do
    holding = position.merge("quantity" => "1")
    earlier_buy = Time.current - 3.hours
    sale_time = Time.current - 2.hours
    later_buy = Time.current - 1.hour

    stub_snapshot(positions: [ holding ])
    stub_broker_trades(
      cash_event("buy-later", "BUY", at: later_buy),
      cash_event("sell", "SELL", at: sale_time)
    )
    @client.stubs(:trade).with("portfolio", "buy-later").returns(broker(trade("buy-later", "BUY", "1", "80", "80")))
    @client.stubs(:trade).with("portfolio", "sell").returns(broker(trade("sell", "SELL", "1", "100", "100")))
    run_sync

    travel 30.minutes
    stub_snapshot(positions: [ holding ])
    stub_broker_trades(cash_event("buy", "BUY", at: Time.current - 1.minute))
    detail = trade("buy", "BUY", "1", "50", "50")
    detail["history"] = [ { "state" => "FINAL_FILL", "timestamp" => earlier_buy.iso8601 } ]
    @client.stubs(:trade).with("portfolio", "buy").returns(broker(detail))
    run_sync

    account = @item.scalable_capital_accounts.brokerage.sole.account
    account.update!(cost_basis_method: "fifo")
    Holding::Materializer.new(account, strategy: :reverse).materialize_holdings
    sale = account.entries.trades.find_by!(external_id: "sell")
    buy = account.entries.trades.find_by!(external_id: "buy")

    assert_equal [ "buy", "sell", "buy-later" ], account.entries.trades.chronological.pluck(:external_id)
    disposal = HoldingLotDisposal.find_by!(sale_entry: sale)
    assert_equal 50.to_d, disposal.unit_cost
    assert_equal buy.id, disposal.lot_source_entry_id
    assert_equal [ buy.id ], sale.entryable.lot_choices.pluck(:id)
  end

  test "applies default household sharing to every new Scalable account" do
    admin = users(:family_admin)
    member = users(:family_member)
    @family.update!(default_account_sharing: "shared")
    @item.update!(owner: admin)
    stub_snapshot
    run_sync

    assert_equal 3, @item.accounts.accessible_by(member).count
    @item.accounts.each do |account|
      assert_equal admin.id, account.owner_id
      assert_equal "read_write", account.account_shares.find_by!(user: member).permission
    end
  end

  test "preserves private household sharing on new Scalable accounts" do
    @family.update!(default_account_sharing: "private")
    @item.update!(owner: users(:family_admin))
    stub_snapshot
    run_sync

    assert_equal 3, @item.accounts.count
    assert_empty @item.accounts.accessible_by(users(:family_member))
  end

  test "first sync saves dated holdings and anchor and protects a later anchor" do
    date = Date.current.yesterday
    stub_snapshot(valuation_at: 1.day.ago)
    run_sync

    broker = @item.scalable_capital_accounts.brokerage.sole.account
    assert_predicate broker, :has_current_anchor?
    assert_equal date, broker.current_anchor_date
    assert_equal date, broker.holdings.where.not(account_provider_id: nil).sole.date

    stub_snapshot(valuation_at: 2.days.ago, securities_value: "0", positions: [])
    run_sync

    assert_equal date, broker.reload.current_anchor_date
    assert_equal 1000.to_d, broker.balance
    assert_equal 2.5.to_d, broker.holdings.where.not(account_provider_id: nil).sole.qty
  end

  test "temporary security lookup failure retries without duplicating holdings or trades" do
    isin = position.fetch("isin")
    stub_snapshot
    with_failed_security_lookup(isin) { run_sync }

    placeholder = Security.find(@item.reload.security_ids.fetch(isin))
    assert_predicate placeholder, :offline?
    assert_equal "resolution_pending", placeholder.offline_reason

    listing = Security.create!(ticker: "EUNL", name: "Example ETF", exchange_operating_mic: "XETR",
                               offline: true, offline_reason: "resolution_pending", failed_fetch_count: 2, failed_fetch_at: 1.day.ago)
    listing.search_isin = isin
    listing.search_currency = "EUR"
    listing.price_provider = "yahoo_finance"
    Security.expects(:search_provider)
      .with(isin, country_code: "DE", technical_failure: kind_of(Proc)).once.returns([ listing ])
    travel 1.day
    stub_snapshot
    @client.expects(:trade).never
    run_sync

    broker = @item.scalable_capital_accounts.brokerage.sole.account
    assert_equal listing.id, @item.reload.security_ids.fetch(isin)
    assert_equal [ 2.5.to_d, 2.5.to_d ], broker.holdings.where.not(account_provider_id: nil).order(:date).pluck(:qty)
    assert_equal [ listing.id ], broker.holdings.distinct.pluck(:security_id)
    assert_equal [ listing.id, listing.id ], broker.trades.pluck(:security_id)
    assert_not Security.exists?(placeholder.id)
    refute_predicate listing.reload, :offline?
    assert_nil listing.offline_reason
    assert_equal 0, listing.failed_fetch_count
    assert_nil listing.failed_fetch_at
    assert_equal "yahoo_finance", listing.price_provider

    Security.expects(:search_provider).never
    travel 1.day
    stub_snapshot
    run_sync

    assert_equal listing.id, @item.reload.security_ids.fetch(isin)
    assert_equal 2, broker.trades.count
  end

  test "verified listings with an unrelated offline reason stay offline" do
    isin = position.fetch("isin")
    listing = Security.create!(ticker: "EUNL", exchange_operating_mic: "XETR",
                               offline: true, offline_reason: "health_check_failed")
    listing.search_isin = isin
    Security.expects(:search_provider)
      .with(isin, country_code: "DE", technical_failure: kind_of(Proc)).once.returns([ listing ])
    stub_snapshot
    run_sync

    assert_equal listing.id, @item.reload.security_ids.fetch(isin)
    assert_predicate listing.reload, :offline?
    assert_equal "health_check_failed", listing.offline_reason
  end

  test "retries a trade-only ISIN after its history window has passed" do
    isin = position.fetch("isin")
    stub_snapshot(positions: [], securities_value: "0")
    with_failed_security_lookup(isin) { run_sync }

    placeholder = Security.find(@item.reload.security_ids.fetch(isin))
    listing = Security.new(ticker: "EUNL", name: "Example ETF", search_isin: isin, exchange_operating_mic: "XETR")
    Security.expects(:search_provider)
      .with(isin, country_code: "DE", technical_failure: kind_of(Proc)).once.returns([ listing ])
    travel 1.day
    stub_snapshot(positions: [], securities_value: "0")
    @client.expects(:trade).never
    run_sync

    assert_equal placeholder.id, @item.reload.security_ids.fetch(isin)
    assert_equal "EUNL", placeholder.reload.ticker
    refute_predicate placeholder, :offline?
    assert_nil placeholder.offline_reason
  end

  test "caches an ISIN after a successful lookup confirms no listing" do
    isin = position.fetch("isin")
    stub_snapshot
    with_failed_security_lookup(isin) { run_sync }

    placeholder = Security.find(@item.reload.security_ids.fetch(isin))
    Security.expects(:search_provider)
      .with(isin, country_code: "DE", technical_failure: kind_of(Proc)).once.returns([])
    travel 1.day
    stub_snapshot
    run_sync
    assert_nil placeholder.reload.offline_reason

    Security.expects(:search_provider).never
    travel 1.day
    stub_snapshot
    run_sync
    assert_equal placeholder.id, @item.reload.security_ids.fetch(isin)
  end

  test "zero Tagesgeld waits for a positive balance and existing account can return to zero" do
    @item.update!(savings_id: nil)
    stub_snapshot(savings_balance: "0")
    run_sync

    assert_empty @item.scalable_capital_accounts.savings
    assert_nil @item.reload.savings_id
    assert_nil @item.savings_synced_through

    travel 1.day
    stub_snapshot(savings_balance: "50")
    run_sync
    savings = @item.scalable_capital_accounts.savings.sole.account
    assert_equal "savings", @item.reload.savings_id
    assert_equal 50.to_d, savings.balance

    travel 1.day
    stub_snapshot(savings_balance: "0")
    run_sync
    assert_equal savings.id, @item.scalable_capital_accounts.savings.sole.account.id
    assert_equal 0.to_d, savings.reload.balance
  end

  test "changed CLI identity fails before writing financial data" do
    @item.update!(broker_account_id: "original")
    @client.expects(:overview).with("portfolio").returns(broker({}, account_id: "different"))
    assert_raises(Provider::ScalableCapital::AuthenticationError) { run_sync }
    assert_predicate @item.reload, :requires_update?
    assert_empty @item.accounts
  end

  test "unconfigured household cannot run subprocess reads" do
    ScalableCapitalItem.stubs(:configured_family_id).returns(families(:empty).id)
    @client.expects(:overview).never
    assert_raises(Provider::ScalableCapital::Error) { run_sync }
    assert_empty @item.accounts
  end

  test "failed or mismatched savings history is atomic across the connection" do
    stub_snapshot(savings_history_id: "wrong")
    assert_raises(Provider::ScalableCapital::InvalidResponse) { run_sync }
    assert_empty @item.accounts
    assert_nil @item.reload.broker_synced_through
  end

  test "a failed follow-up leaves existing balances and both checkpoints intact" do
    stub_snapshot
    run_sync
    previous = @item.reload.attributes.slice("broker_synced_through", "savings_synced_through")
    # A newer broker cash value must not be committed when savings history fails.
    travel 1.day
    stub_snapshot(savings_history_id: "wrong")
    @client.stubs(:cash).with("portfolio").returns(broker({ "cash_balance" => "999" }))
    assert_raises(Provider::ScalableCapital::InvalidResponse) { run_sync }

    assert_equal previous, @item.reload.attributes.slice(*previous.keys)
    assert_equal 255.25.to_d, @item.scalable_capital_accounts.cash.sole.account.balance
  end

  test "closing a holding writes a zero snapshot and preserves historical quantity" do
    stub_snapshot
    run_sync
    travel 1.day
    stub_snapshot(positions: [], securities_value: "0")
    run_sync

    account = @item.scalable_capital_accounts.brokerage.first.account
    assert_equal [ 2.5.to_d, 0.to_d ], account.holdings.where.not(account_provider_id: nil).order(:date).pluck(:qty)

    travel 1.day
    stub_snapshot(positions: [], securities_value: "0")
    assert_no_difference -> { account.holdings.where.not(account_provider_id: nil).count } do
      run_sync
    end
  end

  private

    def run_sync
      sync = @item.syncs.create!
      ScalableCapitalItem::Syncer.new(@item, client: @client).perform_sync(sync)
    end

    def with_failed_security_lookup(isin)
      Security.stubs(:search_provider).with do |symbol, options|
        next false unless symbol == isin

        options.fetch(:technical_failure).call(nil)
        true
      end.returns([])
      yield
    ensure
      Security.unstub(:search_provider)
    end

    def stub_snapshot(positions: [ position ], securities_value: "1000", savings_history_id: "savings",
                      savings_balance: "50", valuation_at: Time.current)
      @client.stubs(:overview).with("portfolio").returns(broker({
        "timestamps" => { "valuation_timestamp_utc" => valuation_at.iso8601 },
        "valuation" => { "total" => "1255.25", "securities" => securities_value, "crypto" => "0" }
      }))
      @client.stubs(:cash).with("portfolio").returns(broker({ "cash_balance" => "255.25" }))
      @client.stubs(:holdings).with("portfolio").returns(broker({ "items" => positions }))
      @client.stubs(:trade).with("portfolio", "buy").returns(broker(trade("buy", "BUY", "2.5", "120", "301")))
      @client.stubs(:trade).with("portfolio", "sell").returns(broker(trade("sell", "SELL", "1", "100", "98")))
      @client.stubs(:overnight).with(@item.reload.savings_id).returns(savings({ "balance" => savings_balance }))
      @client.stubs(:broker_transactions).with("portfolio", all_of(has_key(:since), has_key(:before))).yields(broker({}), broker_events)
      @client.stubs(:overnight_transactions).with("savings", all_of(has_key(:since), has_key(:before)))
        .yields(savings({}, id: savings_history_id), [
          cash_event("interest", "INTEREST", amount: "1.25"),
          cash_event("cash-transfer-out", "CASH_TRANSFER_OUT", amount: "20")
        ])
    end

    def stub_broker_trades(*events)
      rows = events.map { |event| event.merge("summary_type" => "BrokerSecurityTransactionSummary") }
      @client.stubs(:broker_transactions).with("portfolio", all_of(has_key(:since), has_key(:before))).yields(broker({}), rows)
    end

    def broker_events
      [
        cash_event("buy", "BUY").merge("summary_type" => "BrokerSecurityTransactionSummary"),
        cash_event("sell", "SELL").merge("summary_type" => "BrokerSecurityTransactionSummary"),
        cash_event("dividend", "DISTRIBUTION", amount: "2.50"),
        cash_event("fee", "FEE", amount: "0.99"),
        cash_event("cash-transfer-in", "CASH_TRANSFER_IN", amount: "20"),
        cash_event("pending", "INTEREST").merge("status" => "PENDING"),
        cash_event("cancelled", "INTEREST").merge("is_cancellation" => true)
      ]
    end

    def position
      { "isin" => "IE00B4L5Y983", "name" => "Example ETF", "quantity" => "2.5", "valuation" => "1000",
        "valuation_currency" => "EUR", "fifo_price" => "110" }
    end

    def broker(result, account_id: "person")
      { "account_id" => account_id, "portfolio_id" => "portfolio", "result" => result }
    end

    def savings(result, id: "savings")
      { "savings_account_id" => id, "account" => { "owner_kind" => "personal", "is_active" => true }, "result" => result }
    end

    def cash_event(id, type, amount: "10", at: Time.iso8601("2026-11-19T23:30:00Z"))
      { "id" => id, "type" => type, "currency" => "EUR", "status" => "SETTLED", "amount" => amount,
        "is_cancellation" => false, "last_event_datetime" => at.iso8601 }
    end

    def trade(id, side, quantity, price, total)
      {
        "id" => id, "currency" => "EUR", "is_pending" => false, "is_cancellation" => false,
        "security" => { "isin" => "IE00B4L5Y983", "name" => "Example ETF" },
        "security_trade" => {
          "side" => side, "status" => "FILLED", "number_of_shares" => { "filled" => quantity },
          "average_price" => price, "total_amount" => total
        }
      }
    end
end
