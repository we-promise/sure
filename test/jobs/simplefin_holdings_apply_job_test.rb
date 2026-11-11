require "test_helper"

class SimplefinHoldingsApplyJobTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @item = SimplefinItem.create!(family: @family, name: "SF", access_url: "https://example.com/x")

    @account = accounts(:investment)

    # Link SFA to existing investment account via legacy association for simplicity
    @sfa = @item.simplefin_accounts.create!(
      name: "Invest",
      account_id: "sf_invest_1",
      currency: "USD",
      account_type: "investment",
      current_balance: 10_000
    )
    @account.update!(simplefin_account_id: @sfa.id)
  end

  test "materializes holdings from raw_holdings_payload and is idempotent" do
    # Clear existing fixture holdings so we can test clean creation
    @account.holdings.delete_all

    # Two holdings: one AAPL (existing security), one NEWCO (should be created)
    @sfa.update!(
      raw_holdings_payload: [
        {
          "id" => "h1",
          "symbol" => "AAPL",
          "quantity" => 10,
          "market_value" => 2000,
          "currency" => "USD"
        },
        {
          "id" => "h2",
          "symbol" => "NEWCO",
          "quantity" => 5,
          "market_value" => 500,
          "currency" => "USD"
        }
      ]
    )

    assert_difference "Holding.where(account: @account).count", 2 do
      SimplefinHoldingsApplyJob.perform_now(@sfa.id)
    end


    # Running again should not create duplicates (external_id uniqueness)
    assert_no_difference "Holding.where(account: @account).count" do
      SimplefinHoldingsApplyJob.perform_now(@sfa.id)
    end

    holdings = @account.holdings.order(:external_id)
    aapl = holdings.find { |h| h.security.ticker == "AAPL" }
    refute_nil aapl
    assert_equal 10, aapl.qty
    assert_equal Money.new(2000, "USD"), aapl.amount_money

    newco_sec = Security.find_by(ticker: "NEWCO")
    refute_nil newco_sec, "should create NEWCO security via resolver when missing"
  end

  test "uses market_value for price and does not confuse value with market_value" do
    # Regression test for GH #1182: some brokerages (Vanguard, Fidelity) include a
    # "value" field that represents cost basis, not market value. The processor must
    # use "market_value" for price derivation and treat "value" as a cost_basis fallback.
    @account.holdings.delete_all

    @sfa.update!(
      raw_holdings_payload: [
        {
          "id" => "h_vanguard",
          "symbol" => "VFIAX",
          "shares" => 50,
          "market_value" => 22626.42,
          "cost_basis" => 22004.40,
          "value" => 22004.40,
          "currency" => "USD"
        }
      ]
    )

    assert_difference "Holding.where(account: @account).count", 1 do
      SimplefinHoldingsApplyJob.perform_now(@sfa.id)
    end

    holding = @account.holdings.find_by(external_id: "simplefin_h_vanguard_#{Date.current}")
    refute_nil holding

    # Price should be derived from market_value / shares, NOT from value / shares
    expected_price = BigDecimal("22626.42") / BigDecimal("50")
    assert_in_delta expected_price.to_f, holding.price.to_f, 0.01,
      "price should be market_value/qty (#{expected_price}), not value/qty"

    # Amount should reflect market_value, not cost basis
    assert_in_delta 22626.42, holding.amount.to_f, 0.01
  end

  test "falls back to value for cost_basis when cost_basis field is absent" do
    @account.holdings.delete_all

    @sfa.update!(
      raw_holdings_payload: [
        {
          "id" => "h_fallback",
          "symbol" => "FXAIX",
          "shares" => 100,
          "market_value" => 50000,
          "value" => 45000,
          "currency" => "USD"
        }
      ]
    )

    assert_difference "Holding.where(account: @account).count", 1 do
      SimplefinHoldingsApplyJob.perform_now(@sfa.id)
    end

    holding = @account.holdings.find_by(external_id: "simplefin_h_fallback_#{Date.current}")
    refute_nil holding

    # Price derived from market_value
    assert_in_delta 500.0, holding.price.to_f, 0.01

    # cost_basis should fall back to "value" field and normalize total basis to per-share basis
    assert_in_delta 450.0, holding.cost_basis.to_f, 0.01
  end

  test "an explicit empty snapshot closes current provider positions without rewriting history or manual holdings" do
    provider = @sfa.ensure_account_provider!
    security = Security.create!(ticker: "CUSTOM:CLOSED", name: "Closed position")
    history = @account.holdings.create!(security: security, account_provider: provider,
      date: Date.yesterday, qty: 2, amount: 200, price: 100, currency: "USD")
    current = @account.holdings.create!(security: security, account_provider: provider,
      date: Date.current, qty: 2, amount: 200, price: 100, currency: "USD",
      cost_basis: 90, cost_basis_locked: true, cost_basis_source: "manual")
    manual = @account.holdings.where(account_provider_id: nil).first!
    manual_values = manual.attributes
    @sfa.update!(raw_holdings_payload: [], raw_payload: { holdings: [] })

    2.times { SimplefinHoldingsApplyJob.perform_now(@sfa.id) }

    assert_empty @account.current_holdings
    assert_equal 0, current.reload.qty
    assert_equal 90, current.cost_basis
    assert_equal 2, history.reload.qty
    assert_equal manual_values, manual.reload.attributes
    assert_equal 2, @account.holdings.where(account_provider: provider).count
  end

  test "an empty snapshot on a later day preserves remapping and historical holdings" do
    provider = @sfa.ensure_account_provider!
    original_security = Security.create!(ticker: "CUSTOM:ORIGINAL", name: "Original position")
    chosen_security = Security.create!(ticker: "CUSTOM:REMAPPED", name: "User chosen position")
    history = @account.holdings.create!(security: chosen_security, provider_security: original_security,
      account_provider: provider, date: Date.yesterday, qty: 3, amount: 300,
      price: 100, currency: "USD", security_locked: true, cost_basis: 80,
      cost_basis_locked: true, cost_basis_source: "manual")
    @sfa.update!(raw_holdings_payload: [], raw_payload: { holdings: [] })

    SimplefinHoldingsApplyJob.perform_now(@sfa.id)

    closed = @account.holdings.find_by!(account_provider: provider, date: Date.current)
    assert_equal 0, closed.qty
    assert_equal chosen_security.id, closed.security_id
    assert_equal 80, closed.cost_basis
    assert_equal 3, history.reload.qty
    assert_empty @account.current_holdings
  end

  test "an omitted holdings field does not close provider positions" do
    provider = @sfa.ensure_account_provider!
    position = @account.holdings.first!
    position.update!(account_provider: provider)
    before = position.attributes
    @sfa.update!(raw_holdings_payload: nil, raw_payload: { balance: "100" })

    SimplefinHoldingsApplyJob.perform_now(@sfa.id)

    assert_equal before, position.reload.attributes
  end

  test "a later empty snapshot does not create another zero row" do
    provider = @sfa.ensure_account_provider!
    security = Security.create!(ticker: "CUSTOM:ALREADY_CLOSED", name: "Closed position")
    @account.holdings.create!(security: security, account_provider: provider,
      date: Date.yesterday, qty: 0, amount: 0, price: 0, currency: "USD")
    @sfa.update!(raw_holdings_payload: [])

    assert_no_difference "@account.holdings.count" do
      SimplefinHoldingsApplyJob.perform_now(@sfa.id)
    end
  end

  test "an empty snapshot closes a zero quantity position with a remaining amount" do
    provider = @sfa.ensure_account_provider!
    security = Security.create!(ticker: "CUSTOM:RESIDUAL", name: "Residual value")
    position = @account.holdings.create!(security: security, account_provider: provider,
      date: Date.current, qty: 0, amount: 10, price: 0, currency: "USD")
    @sfa.update!(raw_holdings_payload: [])

    SimplefinHoldingsApplyJob.perform_now(@sfa.id)

    assert_equal 0, position.reload.amount
  end

  test "an empty legacy Crypto snapshot claims only identifiable SimpleFIN holdings" do
    @account.update!(simplefin_account_id: nil)
    @account = accounts(:crypto)
    @account.update!(simplefin_account_id: @sfa.id)
    @sfa.reload
    security = Security.create!(ticker: "CUSTOM:LEGACY", name: "Legacy position")
    legacy = @account.holdings.create!(security: security, date: Date.yesterday,
      qty: 2, amount: 200, price: 100, currency: "USD", external_id: "simplefin_legacy_#{Date.yesterday}")
    manual = @account.holdings.create!(security: securities(:aapl), date: Date.current,
      qty: 3, amount: 300, price: 100, currency: "USD")
    unrelated = @account.holdings.create!(security: security, date: 2.days.ago,
      qty: 4, amount: 400, price: 100, currency: "USD", external_id: "another_provider")
    manual_values, unrelated_values = manual.attributes, unrelated.attributes
    @sfa.update!(raw_holdings_payload: [])

    SimplefinHoldingsApplyJob.perform_now(@sfa.id)

    provider = @sfa.reload.account_provider
    assert_not_nil provider
    assert_equal provider.id, legacy.reload.account_provider_id
    assert_equal 2, legacy.qty
    assert_equal 0, @account.holdings.find_by!(account_provider: provider, date: Date.current).qty
    assert_equal manual_values, manual.reload.attributes
    assert_equal unrelated_values, unrelated.reload.attributes
    assert_empty @account.current_holdings
  end

  [ false, true ].each do |remapped|
    test "closing a #{remapped ? 'remapped' : 'normal'} provider position preserves a same-day manual collision" do
      provider = @sfa.ensure_account_provider!
      security = Security.create!(ticker: "CUSTOM:COLLISION", name: "Chosen security")
      original = Security.create!(ticker: "CUSTOM:COLLISION_ORIGINAL", name: "Original security") if remapped
      history = @account.holdings.create!(security: security, provider_security: original, security_locked: remapped,
        account_provider: provider, date: Date.yesterday, qty: 2, amount: 200, price: 100, currency: "USD",
        cost_basis: 90, cost_basis_locked: true, cost_basis_source: "manual")
      manual = @account.holdings.create!(security: security, date: Date.current,
        qty: 3, amount: 300, price: 100, currency: "USD")
      history_values, manual_values = history.attributes, manual.attributes
      @sfa.update!(raw_holdings_payload: [])

      assert_no_difference "@account.holdings.count" do
        2.times { SimplefinHoldingsApplyJob.perform_now(@sfa.id) }
      end

      assert_equal manual_values, manual.reload.attributes
      assert_equal history_values, history.reload.attributes
      assert_empty @account.current_holdings
    end
  end

  test "a stale processor reloads the latest snapshot before closing positions" do
    provider = @sfa.ensure_account_provider!
    @sfa.update!(raw_holdings_payload: [], raw_payload: { holdings: [] })
    processor = SimplefinAccount::Investments::HoldingsProcessor.new(@sfa)
    holding = { "id" => "position", "symbol" => "CUSTOM:LATEST", "shares" => "4", "market_value" => "400", "currency" => "USD" }
    SimplefinAccount.find(@sfa.id).update!(raw_holdings_payload: [ holding ], raw_payload: { holdings: [ holding ] })

    processor.process

    assert_equal [ 4.to_d ], @account.holdings.where(account_provider: provider).pluck(:qty)
  end
end
