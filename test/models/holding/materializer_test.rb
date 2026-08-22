require "test_helper"

class Holding::MaterializerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Test", balance: 20000, cash_balance: 20000, currency: "USD", accountable: Investment.new)
    @aapl = securities(:aapl)
    @msft = securities(:msft)
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

  test "preserves calculated history for provider-sourced holdings on reverse materialization" do
    coinstats_item = @family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(
      name: "Brokerage",
      currency: "USD"
    )
    account_provider = AccountProvider.create!(account: @account, provider: coinstats_account)

    Holding.create!(
      account: @account,
      security: @aapl,
      qty: 10,
      price: 200,
      amount: 2000,
      currency: "USD",
      date: Date.current,
      account_provider: account_provider
    )

    Holding::Materializer.new(@account, strategy: :reverse).materialize_holdings

    today_holding = @account.holdings.find_by!(security: @aapl, date: Date.current, currency: "USD")
    yesterday_holding = @account.holdings.find_by!(security: @aapl, date: Date.yesterday, currency: "USD")

    assert_equal account_provider.id, today_holding.account_provider_id
    assert_nil yesterday_holding.account_provider_id
    assert_equal BigDecimal("10"), yesterday_holding.qty
    assert_equal yesterday_holding.qty * yesterday_holding.price, yesterday_holding.amount
  end

  test "cleans up calculated current-day holdings when a provider snapshot exists in another currency" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.current, rate: 1.2)

    coinstats_item = @family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(
      name: "Brokerage",
      currency: "USD"
    )
    account_provider = AccountProvider.create!(account: @account, provider: coinstats_account)

    Holding.create!(
      account: @account,
      security: @aapl,
      qty: 10,
      price: 200,
      amount: 2000,
      currency: "EUR",
      date: Date.current,
      account_provider: account_provider,
      cost_basis: 150
    )

    Holding::Materializer.new(@account, strategy: :reverse).materialize_holdings

    today_holdings = @account.holdings.where(security: @aapl, date: Date.current).order(:currency)

    assert_equal [ "EUR" ], today_holdings.pluck(:currency)
    assert_equal [ account_provider.id ], today_holdings.pluck(:account_provider_id)
  end

  test "carries forward provider cost_basis to calculated rows past the provider snapshot date" do
    coinstats_item = @family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Brokerage", currency: "USD")
    account_provider = AccountProvider.create!(account: @account, provider: coinstats_account)

    # Provider snapshot two days ago with known cost basis, but no trades.
    # This mirrors IBKR Flex where the export ends on Friday but today is Sunday.
    Holding.create!(
      account: @account,
      security: @aapl,
      qty: 10,
      price: 200,
      amount: 2000,
      currency: "USD",
      date: 2.days.ago.to_date,
      account_provider: account_provider,
      cost_basis: BigDecimal("125.50"),
      cost_basis_source: "provider"
    )

    Holding::Materializer.new(@account, strategy: :reverse).materialize_holdings

    today_holding = @account.holdings.find_by!(security: @aapl, date: Date.current, currency: "USD")
    assert_nil today_holding.account_provider_id,
      "Today's row is calculated, not a provider snapshot"
    assert_equal BigDecimal("125.50"), today_holding.cost_basis,
      "Today's calculated row should inherit the provider's cost_basis so trend/return calcs work"
    assert_equal "provider", today_holding.cost_basis_source
  end

  test "does not overwrite an existing calculated cost_basis with provider carry-forward" do
    coinstats_item = @family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Brokerage", currency: "USD")
    account_provider = AccountProvider.create!(account: @account, provider: coinstats_account)

    Holding.create!(
      account: @account,
      security: @aapl,
      qty: 10,
      price: 200,
      amount: 2000,
      currency: "USD",
      date: 2.days.ago.to_date,
      account_provider: account_provider,
      cost_basis: BigDecimal("125.50"),
      cost_basis_source: "provider"
    )

    # Pre-existing calculated row for today (e.g., from a prior trade-derived run)
    Holding.create!(
      account: @account,
      security: @aapl,
      qty: 10,
      price: 200,
      amount: 2000,
      currency: "USD",
      date: Date.current,
      cost_basis: BigDecimal("180.00"),
      cost_basis_source: "calculated"
    )

    Holding::Materializer.new(@account, strategy: :reverse).materialize_holdings

    today_holding = @account.holdings.find_by!(security: @aapl, date: Date.current, currency: "USD")
    assert_equal BigDecimal("180.00"), today_holding.cost_basis,
      "Existing calculated cost_basis must beat provider carry-forward"
    assert_equal "calculated", today_holding.cost_basis_source
  end

  test "refreshes stale provider carry-forward when a newer provider snapshot arrives" do
    coinstats_item = @family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Brokerage", currency: "USD")
    account_provider = AccountProvider.create!(account: @account, provider: coinstats_account)

    # With no entries, start_date = yesterday, so materializer only descends to
    # yesterday. Use an older date so the second snapshot doesn't land on a date
    # the materializer already owns.
    Holding.create!(
      account: @account, security: @aapl, qty: 10, price: 200, amount: 2000,
      currency: "USD", date: 5.days.ago.to_date,
      account_provider: account_provider,
      cost_basis: BigDecimal("100.00"), cost_basis_source: "provider"
    )

    Holding::Materializer.new(@account, strategy: :reverse).materialize_holdings

    today_holding = @account.holdings.find_by!(security: @aapl, date: Date.current, currency: "USD")
    assert_equal BigDecimal("100.00"), today_holding.cost_basis

    # Provider publishes a newer snapshot with an updated cost_basis on a date
    # that falls outside the materializer's window (older than start_date).
    Holding.create!(
      account: @account, security: @aapl, qty: 10, price: 210, amount: 2100,
      currency: "USD", date: 3.days.ago.to_date,
      account_provider: account_provider,
      cost_basis: BigDecimal("150.00"), cost_basis_source: "provider"
    )

    Holding::Materializer.new(@account, strategy: :reverse).materialize_holdings

    today_holding.reload
    assert_equal BigDecimal("150.00"), today_holding.cost_basis,
      "Carry-forward should update to the newer provider snapshot value"
    assert_equal "provider", today_holding.cost_basis_source
  end

  test "carry-forward is a no-op for forward-strategy accounts without provider holdings" do
    create_trade(@aapl, account: @account, qty: 5, price: 200, date: Date.current)

    assert_nothing_raised do
      Holding::Materializer.new(@account, strategy: :forward).materialize_holdings
    end

    today_holding = @account.holdings.find_by!(security: @aapl, date: Date.current, currency: "USD")
    assert_equal "calculated", today_holding.cost_basis_source
    assert_equal BigDecimal("200.00"), today_holding.cost_basis,
      "Forward strategy with no provider rows should compute cost_basis from trades normally"
  end

  test "does not overwrite a zero-valued manual cost_basis with provider carry-forward" do
    coinstats_item = @family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Brokerage", currency: "USD")
    account_provider = AccountProvider.create!(account: @account, provider: coinstats_account)

    Holding.create!(
      account: @account, security: @aapl,
      qty: 10, price: 200, amount: 2000, currency: "USD",
      date: 2.days.ago.to_date,
      account_provider: account_provider,
      cost_basis: BigDecimal("125.50"), cost_basis_source: "provider"
    )

    # Free shares: legitimate zero-cost basis recorded manually
    Holding.create!(
      account: @account, security: @aapl,
      qty: 10, price: 200, amount: 2000, currency: "USD",
      date: Date.current,
      cost_basis: BigDecimal("0"), cost_basis_source: "manual"
    )

    Holding::Materializer.new(@account, strategy: :reverse).materialize_holdings

    today_holding = @account.holdings.find_by!(security: @aapl, date: Date.current, currency: "USD")
    assert_equal BigDecimal("0"), today_holding.cost_basis,
      "Zero-valued manual cost_basis (e.g., free shares) must not be overwritten by provider carry-forward"
    assert_equal "manual", today_holding.cost_basis_source
  end

  test "carry-forward converts provider cost_basis currency when provider and calculated currencies differ" do
    snap_date = 2.days.ago.to_date
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: snap_date, rate: 1.2)

    coinstats_item = @family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Brokerage", currency: "EUR")
    account_provider = AccountProvider.create!(account: @account, provider: coinstats_account)

    Holding.create!(
      account: @account, security: @aapl,
      qty: 10, price: 200, amount: 2000, currency: "EUR",
      date: snap_date,
      account_provider: account_provider,
      cost_basis: BigDecimal("100.00"), cost_basis_source: "provider"
    )

    Holding::Materializer.new(@account, strategy: :reverse).materialize_holdings

    today_holding = @account.holdings.find_by!(security: @aapl, date: Date.current, currency: "USD")
    assert_in_delta BigDecimal("120.00"), today_holding.cost_basis, BigDecimal("0.01"),
      "Provider cost_basis in EUR should be converted to USD at the snapshot-date exchange rate"
    assert_equal "provider", today_holding.cost_basis_source
  end

  test "carry-forward skips provider cost_basis when FX conversion raises Money::ConversionError" do
    snap_date = 2.days.ago.to_date
    # No ExchangeRate created — EUR→USD conversion will raise Money::ConversionError

    coinstats_item = @family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Brokerage", currency: "EUR")
    account_provider = AccountProvider.create!(account: @account, provider: coinstats_account)

    Holding.create!(
      account: @account, security: @aapl,
      qty: 10, price: 200, amount: 2000, currency: "EUR",
      date: snap_date,
      account_provider: account_provider,
      cost_basis: BigDecimal("100.00"), cost_basis_source: "provider"
    )

    assert_nothing_raised do
      Holding::Materializer.new(@account, strategy: :reverse).materialize_holdings
    end

    today_holding = @account.holdings.find_by!(security: @aapl, date: Date.current, currency: "USD")
    assert_nil today_holding.cost_basis,
      "Carry-forward should be skipped gracefully when currency conversion fails"
  end

  test "preserves same-day non-provider holdings for securities absent from the provider snapshot" do
    ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: Date.current, rate: 1.2)

    coinstats_item = @family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(
      name: "Brokerage",
      currency: "USD"
    )
    account_provider = AccountProvider.create!(account: @account, provider: coinstats_account)

    Holding.create!(
      account: @account,
      security: @aapl,
      qty: 10,
      price: 200,
      amount: 2000,
      currency: "EUR",
      date: Date.current,
      account_provider: account_provider,
      cost_basis: 150
    )

    manual_holding = Holding.create!(
      account: @account,
      security: @msft,
      qty: 3,
      price: 250,
      amount: 750,
      currency: "USD",
      date: Date.current,
      cost_basis: 225,
      cost_basis_source: "manual",
      cost_basis_locked: true
    )

    Holding::Materializer.new(@account, strategy: :reverse).materialize_holdings

    assert_equal manual_holding.id, manual_holding.reload.id
    assert_equal @msft.id, manual_holding.security_id
    assert_nil manual_holding.account_provider_id

    today_holdings = @account.holdings.where(date: Date.current)

    assert_equal(
      [ [ @aapl.id, "EUR" ], [ @msft.id, "USD" ] ].sort,
      today_holdings.pluck(:security_id, :currency).sort
    )
  end
end
