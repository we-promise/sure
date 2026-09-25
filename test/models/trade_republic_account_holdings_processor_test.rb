require "test_helper"

class TradeRepublicAccountHoldingsProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = trade_republic_items(:configured_item)
    @item.trade_republic_accounts.destroy_all

    @tr_account = @item.trade_republic_accounts.create!(
      name: "Holdings Test",
      trade_republic_account_id: "DEHOLD1",
      currency: "EUR"
    )
    @account = @family.accounts.create!(
      name: "Trade Republic Holdings Test",
      balance: 0,
      cash_balance: 0,
      currency: "EUR",
      accountable: Investment.new
    )
    @tr_account.ensure_account_provider!(@account)
    @tr_account.reload
  end

  test "imports holding with fractional quantity and exact math" do
    import_position(isin: "US0378331005", quantity: "13.439945", price: "183.94", average_cost: "150.10")

    holding = @account.holdings.find_by(external_id: "trade_republic_position_DEHOLD1_US0378331005_#{Date.current}")

    assert_not_nil holding
    assert_equal BigDecimal("13.439945"), holding.qty
    assert_equal BigDecimal("13.439945").to_s, holding.qty.to_s
    assert_equal BigDecimal("183.94"), holding.price

    # qty keeps 8 fractional digits; the amount column stores scale-4
    # (Sure-wide convention), so compare against the same rounding.
    expected_amount = (BigDecimal("13.439945") * BigDecimal("183.94")).round(4)
    assert_equal expected_amount, holding.amount
  end

  test "sync twice keeps a single holding per position" do
    position = position_payload(isin: "US0378331005", quantity: "13.439945", price: "183.94")

    @tr_account.update!(raw_positions_payload: [ position ])
    TradeRepublicAccount::HoldingsProcessor.new(@tr_account).process

    assert_no_difference "@account.holdings.count" do
      TradeRepublicAccount::HoldingsProcessor.new(@tr_account.reload).process
    end
  end

  test "position without valid price is skipped rather than guessed" do
    assert_no_difference "@account.holdings.count" do
      import_position(isin: "US0378331005", quantity: "13.439945", price: nil)
    end
  end

  test "empty portfolio creates no holdings and preserves prior financial state" do
    import_position(isin: "US5933661043", quantity: "2", price: "100")
    holdings_before = @account.holdings.count

    # Successful but empty snapshot: nothing new to import, nothing destroyed.
    @tr_account.update!(raw_positions_payload: [])
    TradeRepublicAccount::HoldingsProcessor.new(@tr_account.reload).process

    assert_equal holdings_before, @account.holdings.count
  end

  test "explicit successful empty portfolio removes prior Trade Republic holdings" do
    import_position(isin: "US5933661043", quantity: "2", price: "100")
    @tr_account.update!(holdings_snapshot_complete: true, raw_positions_payload: [])

    TradeRepublicAccount::HoldingsProcessor.new(@tr_account.reload).process

    assert_nil @account.holdings.find_by(external_id: "trade_republic_position_DEHOLD1_US5933661043_#{Date.current}")
  end

  test "complete snapshot removes stale Trade Republic holdings" do
    import_position(isin: "US5933661043", quantity: "2", price: "100")
    @tr_account.update!(holdings_snapshot_complete: true)

    @tr_account.update!(raw_positions_payload: [ position_payload(isin: "US0378331005", quantity: "1", price: "200") ])
    TradeRepublicAccount::HoldingsProcessor.new(@tr_account.reload).process

    assert_nil @account.holdings.find_by(external_id: "trade_republic_position_DEHOLD1_US5933661043_#{Date.current}")
    assert_not_nil @account.holdings.find_by(external_id: "trade_republic_position_DEHOLD1_US0378331005_#{Date.current}")
  end

  test "complete snapshot preserves holdings from previous dates" do
    import_position(isin: "US5933661043", quantity: "2", price: "100")
    historical_holding = @account.holdings.find_by!(external_id: "trade_republic_position_DEHOLD1_US5933661043_#{Date.current}")
    historical_holding.update!(external_id: "trade_republic_position_DEHOLD1_US5933661043_#{Date.yesterday}")

    @tr_account.update!(holdings_snapshot_complete: true, raw_positions_payload: [])
    TradeRepublicAccount::HoldingsProcessor.new(@tr_account.reload).process

    assert @account.holdings.exists?(external_id: "trade_republic_position_DEHOLD1_US5933661043_#{Date.yesterday}")
  end

  test "incomplete snapshot preserves stale Trade Republic holdings" do
    import_position(isin: "US5933661043", quantity: "2", price: "100")
    @tr_account.update!(holdings_snapshot_complete: false)

    @tr_account.update!(raw_positions_payload: [ position_payload(isin: "US0378331005", quantity: "1", price: "200") ])
    TradeRepublicAccount::HoldingsProcessor.new(@tr_account.reload).process

    assert_not_nil @account.holdings.find_by(external_id: "trade_republic_position_DEHOLD1_US5933661043_#{Date.current}")
  end

  test "zero and negative quantities are not imported" do
    assert_no_difference "@account.holdings.count" do
      @tr_account.update!(raw_positions_payload: [
        position_payload(isin: "US0378331005", quantity: "0", price: "200"),
        position_payload(isin: "US5933661043", quantity: "-1", price: "200")
      ])
      TradeRepublicAccount::HoldingsProcessor.new(@tr_account.reload).process
    end
  end

  test "resolves a holding to an exact exchange ticker and rematches this account only" do
    Security.stubs(:search_provider).returns([])

    isin = "DE000BASF111"
    isin_security = Security.create!(ticker: isin, name: "BASF ISIN", offline: false)
    other_account = @family.accounts.create!(
      name: "Other TR Account",
      balance: 0,
      cash_balance: 0,
      currency: "EUR",
      accountable: Investment.new
    )
    other_holding = other_account.holdings.create!(
      security: isin_security,
      date: Date.current,
      qty: 1,
      price: 40,
      amount: 40,
      currency: "EUR"
    )
    import_position(isin: isin, quantity: "5", price: "42.50")
    holding = @account.holdings.find_by!(security: isin_security)
    trade_entry = @account.entries.create!(
      name: "BASF buy",
      date: Date.current,
      amount: -100,
      currency: "EUR",
      entryable: Trade.new(security: isin_security, qty: 2, price: 50, currency: "EUR")
    )

    @tr_account.update!(raw_positions_payload: [
      position_payload(isin: isin, quantity: "5", price: "42.50", symbol: "BAS", exchange_slug: "XETR")
    ])
    TradeRepublicAccount::HoldingsProcessor.new(@tr_account.reload).process

    resolved = Security.find_by!(ticker: "BAS", exchange_operating_mic: "XETR")
    assert_equal false, resolved.offline?
    assert_equal resolved.id, holding.reload.security_id
    assert_equal resolved.id, trade_entry.reload.entryable.security_id
    assert_equal isin_security.id, other_holding.reload.security_id
    assert Security.exists?(id: isin_security.id)
  end

  test "existing exchange securities keep provider-managed offline states during position imports" do
    [
      [ "DE000BASF111", "BAS", "health_check_failed" ],
      [ "DE000BASF222", "BAS2", "provider_disabled" ]
    ].each do |isin, symbol, reason|
      security = Security.create!(
        ticker: symbol,
        exchange_operating_mic: "XETR",
        name: symbol,
        offline: true,
        offline_reason: reason
      )

      import_position(isin: isin, quantity: "5", price: "42.50", symbol: symbol, exchange_slug: "XETR")

      holding = @account.holdings.find_by!(security: security)
      assert_equal BigDecimal("42.50"), holding.price
      assert security.reload.offline?
      assert_equal reason, security.offline_reason
    end
  end

  test "a ticker rematch uses a new online security while the failed ISIN security stays offline" do
    Security.stubs(:search_provider).returns([])
    isin = "DE000BASF111"

    import_position(isin: isin, quantity: "5", price: "40")
    old_security = Security.find_by!(ticker: isin)
    old_security.update!(offline_reason: "health_check_failed")
    holding = @account.holdings.find_by!(security: old_security)

    import_position(isin: isin, quantity: "5", price: "42.50", symbol: "BAS", exchange_slug: "XETR")

    new_security = Security.find_by!(ticker: "BAS", exchange_operating_mic: "XETR")
    assert old_security.reload.offline?
    assert_equal "health_check_failed", old_security.offline_reason
    assert_not new_security.offline?
    assert_equal new_security.id, holding.reload.security_id
    assert_equal BigDecimal("42.50"), holding.price
  end

  test "a ticker rematch preserves an existing ticker security's offline state" do
    Security.stubs(:search_provider).returns([])
    isin = "DE000BASF111"

    import_position(isin: isin, quantity: "5", price: "40")
    old_security = Security.find_by!(ticker: isin)
    holding = @account.holdings.find_by!(security: old_security)
    ticker_security = Security.create!(
      ticker: "BAS",
      exchange_operating_mic: "XETR",
      name: "BASF",
      offline: true,
      offline_reason: "health_check_failed"
    )

    import_position(isin: isin, quantity: "5", price: "42.50", symbol: "BAS", exchange_slug: "XETR")

    assert ticker_security.reload.offline?
    assert_equal "health_check_failed", ticker_security.offline_reason
    assert_equal ticker_security.id, holding.reload.security_id
    assert_equal BigDecimal("42.50"), holding.price
  end

  test "provider confirmation preserves an existing exchange security's offline state" do
    security = Security.create!(
      ticker: "BAS.DE",
      exchange_operating_mic: "XETR",
      name: "BASF",
      offline: true,
      offline_reason: "health_check_failed"
    )
    Security.stubs(:search_provider).returns([
      Security.new(ticker: "BAS.DE", exchange_operating_mic: "XETR", name: "BASF")
    ])
    @tr_account.update!(raw_positions_payload: [
      position_payload(isin: "DE000BASF111", quantity: "5", price: "42.50", symbol: "BAS", exchange_slug: "XETR")
    ])
    processor = TradeRepublicAccount::HoldingsProcessor.new(@tr_account.reload)
    processor.stubs(:available_price_provider).returns("twelve_data")

    processor.process

    assert_equal security.id, @account.holdings.first.security_id
    assert security.reload.offline?
    assert_equal "health_check_failed", security.offline_reason
    assert_equal "twelve_data", security.price_provider
  end

  test "exchange security creation path preserves an existing offline security" do
    security = Security.create!(
      ticker: "BAS",
      exchange_operating_mic: "XETR",
      name: "BASF",
      offline: true,
      offline_reason: "health_check_failed"
    )
    processor = TradeRepublicAccount::HoldingsProcessor.new(@tr_account.reload)

    resolved = processor.send(
      :find_or_create_exchange_security!,
      ticker: "BAS",
      exchange_operating_mic: "XETR",
      name: "BASF",
      price_provider: "twelve_data"
    )

    assert_equal security.id, resolved.id
    assert security.reload.offline?
    assert_equal "health_check_failed", security.offline_reason
    assert_equal "twelve_data", security.price_provider
  end

  test "a concurrent exchange security insert does not abort the account sync" do
    winner = Security.create!(
      ticker: "BAS", exchange_operating_mic: "XETR", name: "BASF",
      offline: true, offline_reason: "health_check_failed"
    )
    duplicate = Security.new(ticker: "BAS", exchange_operating_mic: "XETR")
    duplicate.stubs(:valid?).returns(true) # Let the database unique index reject the insert.
    Security.stubs(:find_by_ticker_and_exchange).returns(nil, winner)
    Security.stubs(:find_or_initialize_by_ticker_and_exchange).returns(duplicate)
    Security.stubs(:search_provider).returns([])

    ActiveRecord::Base.transaction do
      import_position(isin: "DE000BASF111", quantity: "5", price: "42.50", symbol: "BAS", exchange_slug: "XETR")

      assert_equal winner.id, @account.holdings.first.security_id
      @account.update!(name: "Sync continued")
    end

    assert_equal "Sync continued", @account.reload.name
    assert_equal 1, Security.where(ticker: "BAS", exchange_operating_mic: "XETR").count
    assert winner.reload.offline?
    assert_equal "health_check_failed", winner.offline_reason
  end

  test "a concurrent provider-confirmed insert reuses the confirmed ticker" do
    winner = Security.create!(
      ticker: "BAS.DE", exchange_operating_mic: "XETR", name: "BASF",
      offline: true, offline_reason: "health_check_failed"
    )
    duplicate = Security.new(ticker: "BAS.DE", exchange_operating_mic: "XETR")
    duplicate.stubs(:valid?).returns(true) # Let the database unique index reject the insert.
    Security.stubs(:search_provider).returns([
      Security.new(ticker: "BAS.DE", exchange_operating_mic: "XETR", name: "BASF")
    ])
    Security.stubs(:find_or_initialize_by_ticker_and_exchange).returns(duplicate)
    processor = TradeRepublicAccount::HoldingsProcessor.new(@tr_account.reload)
    processor.stubs(:available_price_provider).returns("twelve_data")

    ActiveRecord::Base.transaction do
      @tr_account.update!(raw_positions_payload: [
        position_payload(isin: "DE000BASF111", quantity: "5", price: "42.50", symbol: "BAS", exchange_slug: "XETR")
      ])
      processor.process

      assert_equal winner.id, @account.holdings.first.security_id
      @account.update!(name: "Sync continued")
    end

    assert_equal "Sync continued", @account.reload.name
    assert_equal 1, Security.where(ticker: "BAS.DE", exchange_operating_mic: "XETR").count
    assert_not Security.exists?(ticker: "BAS", exchange_operating_mic: "XETR")
    assert winner.reload.offline?
    assert_equal "health_check_failed", winner.offline_reason
    assert_equal "twelve_data", winner.price_provider
  end

  test "a provider-confirmed ticker found by validation reuses the existing security" do
    winner = Security.create!(ticker: "BAS.DE", exchange_operating_mic: "XETR", name: "BASF")
    Security.stubs(:search_provider).returns([
      Security.new(ticker: "BAS.DE", exchange_operating_mic: "XETR", name: "BASF")
    ])
    Security.stubs(:find_or_initialize_by_ticker_and_exchange).returns(
      Security.new(ticker: "BAS.DE", exchange_operating_mic: "XETR")
    )
    processor = TradeRepublicAccount::HoldingsProcessor.new(@tr_account.reload)
    processor.stubs(:available_price_provider).returns("twelve_data")
    @tr_account.update!(raw_positions_payload: [
      position_payload(isin: "DE000BASF111", quantity: "5", price: "42.50", symbol: "BAS", exchange_slug: "XETR")
    ])

    processor.process

    assert_equal winner.id, @account.holdings.first.security_id
    assert_equal "twelve_data", winner.reload.price_provider
    assert_not Security.exists?(ticker: "BAS", exchange_operating_mic: "XETR")
  end

  test "rematch prefers exchange market values and merges cost basis on collision" do
    Security.stubs(:search_provider).returns([])

    isin = "DE000BASF111"
    isin_security = Security.create!(ticker: isin, name: "BASF ISIN", offline: true)
    prior_provider_security = Security.create!(ticker: "PRIOR_BAS", name: "Prior BASF", offline: true)
    exchange_security = Security.create!(
      ticker: "BAS",
      exchange_operating_mic: "XETR",
      name: "BASF",
      offline: false
    )

    isin_holding = @account.holdings.create!(
      security: isin_security,
      date: Date.current,
      qty: 3,
      price: 40,
      amount: 120,
      cost_basis: 38,
      currency: "EUR",
      external_id: "stale-isin-holding",
      provider_security_id: prior_provider_security.id,
      account_provider_id: @tr_account.account_provider.id
    )
    exchange_holding = @account.holdings.create!(
      security: exchange_security,
      date: Date.current,
      qty: 5,
      price: 42.5,
      amount: 212.5,
      currency: "EUR",
      external_id: "trade_republic_position_DEHOLD1_#{isin}_#{Date.current}",
      account_provider_id: @tr_account.account_provider.id
    )

    processor = TradeRepublicAccount::HoldingsProcessor.new(@tr_account.reload)
    assert_difference "DebugLogEntry.count", 1 do
      assert_nothing_raised do
        processor.send(:rematch_account_from_isin!, isin, exchange_security)
      end
    end

    assert_not Holding.exists?(isin_holding.id)
    assert Holding.exists?(exchange_holding.id)
    exchange_holding.reload
    assert_equal exchange_security.id, exchange_holding.security_id
    assert_equal BigDecimal("5"), exchange_holding.qty
    assert_equal BigDecimal("212.5"), exchange_holding.amount
    assert_equal BigDecimal("38"), exchange_holding.cost_basis
    assert_equal prior_provider_security.id, exchange_holding.provider_security_id
  end

  test "falls back to an offline ISIN security without a usable exchange symbol" do
    Security.stubs(:search_provider).returns([])

    import_position(isin: "LU3176111881", quantity: "3", price: "10")

    security = Security.find_by!(ticker: "LU3176111881")
    holding = @account.holdings.find_by!(security: security)

    assert security.offline?
    assert_equal "LU3176111881", holding.security.ticker
  end

  test "maps a Trade Republic Tradegate symbol to the Tradegate MIC" do
    Security.stubs(:search_provider).returns([])

    import_position(
      isin: "DE000TRAD123",
      quantity: "2",
      price: "20",
      symbol: "TRD",
      exchange_slug: "TDG"
    )

    security = @account.holdings.first.security
    assert_equal "TRD", security.ticker
    assert_equal "TGAT", security.exchange_operating_mic
  end

  private

    def import_position(isin:, quantity:, price:, average_cost: nil, symbol: nil, exchange_slug: nil)
      @tr_account.update!(raw_positions_payload: [
        position_payload(isin:, quantity:, price:, average_cost:, symbol:, exchange_slug:)
      ])
      TradeRepublicAccount::HoldingsProcessor.new(@tr_account.reload).process
    end

    def position_payload(isin:, quantity:, price:, average_cost: nil, symbol: nil, exchange_slug: nil)
      {
        "isin" => isin,
        "name" => "Test Security",
        "quantity" => quantity,
        "price" => price,
        "average_cost" => average_cost,
        "symbol" => symbol,
        "exchange_slug" => exchange_slug
      }.compact
    end
end
