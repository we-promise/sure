require "test_helper"

class Holding::MaterializerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Test", balance: 20000, cash_balance: 20000, currency: "USD", accountable: Investment.new)
    @aapl = securities(:aapl)
  end

  test "syncs holdings" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: Date.current)

    # Should have yesterday's and today's holdings
    assert_difference "@account.holdings.count", 2 do
      Holding::Materializer.new(@account, strategy: :forward).materialize_holdings
    end
  end

  test "purges stale holdings for unlinked accounts" do
    # Since the account has no entries, there should be no holdings
    Holding.create!(account: @account, security: @aapl, qty: 1, price: 100, amount: 100, currency: "USD", date: Date.current)

    assert_difference "Holding.count", -1 do
      Holding::Materializer.new(@account, strategy: :forward).materialize_holdings
    end
  end

  test "preserves provider cost_basis when trade-derived cost_basis is nil" do
    # Simulate a provider-imported holding with cost_basis (e.g., from SimpleFIN)
    # This is the realistic scenario: linked account with provider holdings but no trades
    provider_cost_basis = BigDecimal("150.00")
    holding = Holding.create!(
      account: @account,
      security: @aapl,
      qty: 10,
      price: 200,
      amount: 2000,
      currency: "USD",
      date: Date.current,
      cost_basis: provider_cost_basis
    )

    # Use :reverse strategy (what linked accounts use) - doesn't purge holdings
    # The AAPL holding has no trades, so computed cost_basis is nil
    # The materializer should preserve the provider cost_basis, not overwrite with nil
    Holding::Materializer.new(@account, strategy: :reverse).materialize_holdings

    holding.reload
    assert_equal provider_cost_basis, holding.cost_basis,
      "Provider cost_basis should be preserved when no trades exist for this security"
  end

  test "updates cost_basis when trade-derived cost_basis is available" do
    # Create a holding with provider cost_basis
    Holding.create!(
      account: @account,
      security: @aapl,
      qty: 10,
      price: 200,
      amount: 2000,
      currency: "USD",
      date: Date.current,
      cost_basis: BigDecimal("150.00")  # Provider says $150
    )

    # Create a trade that gives us a different cost basis
    create_trade(@aapl, account: @account, qty: 10, price: 180, date: Date.current)

    # Use :reverse strategy - with trades, it should compute cost_basis from them
    Holding::Materializer.new(@account, strategy: :reverse).materialize_holdings

    holding = @account.holdings.find_by(security: @aapl, date: Date.current)
    assert_equal BigDecimal("180.00"), holding.cost_basis,
      "Trade-derived cost_basis should override provider cost_basis when available"
  end

  test "recalculates calculated cost_basis when new trades are added" do
    date = Date.current

    create_trade(@aapl, account: @account, qty: 1, price: 3000, date: date)
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    holding = @account.holdings.find_by!(security: @aapl, date: date, currency: "USD")
    assert_equal "calculated", holding.cost_basis_source
    assert_equal BigDecimal("3000.0"), holding.cost_basis

    create_trade(@aapl, account: @account, qty: 1, price: 2500, date: date)
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    holding.reload
    assert_equal "calculated", holding.cost_basis_source
    assert_equal BigDecimal("2750.0"), holding.cost_basis
  end
end
