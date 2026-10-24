require "test_helper"

class Holding::MaterializerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Test", balance: 20000, cash_balance: 20000, currency: "USD", accountable: Investment.new)
    @aapl = securities(:aapl)
    @msft = securities(:msft)
  end

  # The figure carried past a provider's last snapshot is per share, and a
  # split changes how many shares the same money bought. Carried across a
  # 2-for-1 unchanged, every row after the split recorded twice the cost the
  # position actually has — and every gain and return computed from it.
  test "a cost basis carried past a split is restated per post-split share" do
    security = Security.create!(ticker: "CBSP", name: "Carried Basis Split")
    (4.days.ago.to_date..Date.current).each do |date|
      Security::Price.create!(security: security, date: date, price: date < 1.day.ago.to_date ? 200 : 100)
    end

    # An entry so materialisation reaches back past the snapshot's own day;
    # account history starts the day before the first entry.
    @account.entries.create!(
      name: "Opening", date: 4.days.ago.to_date, amount: 20000, currency: "USD",
      entryable: Valuation.new(kind: "opening_anchor")
    )

    coinstats_item = @family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Provider", currency: "USD")
    account_provider = AccountProvider.create!(account: @account, provider: coinstats_account)

    # The provider's last snapshot, before the split: 10 shares at $100 each.
    @account.holdings.create!(
      security: security, date: 3.days.ago.to_date, qty: 10, price: 200, amount: 2000,
      currency: "USD", cost_basis: 100, cost_basis_source: "provider", account_provider: account_provider
    )
    Security::Split.create!(security: security, ex_date: 1.day.ago.to_date, numerator: 2, denominator: 1, source: "manual")

    Holding::Materializer.new(@account, strategy: :reverse).materialize_holdings

    after_split = @account.holdings.find_by!(security: security, date: Date.current)
    before_split = @account.holdings.find_by!(security: security, date: 2.days.ago.to_date)

    assert_equal 100, before_split.cost_basis.to_d, "the snapshot's own terms are untouched before the split"
    assert_equal 50, after_split.cost_basis.to_d, "the same money over twice the shares"
    assert_equal before_split.qty * before_split.cost_basis, after_split.qty * after_split.cost_basis,
      "a split moves no money, so total recorded cost is unchanged"
  end

  test "syncs holdings" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: Date.current)

    # Should have yesterday's and today's holdings
    assert_difference "@account.holdings.count", 2 do
      Holding::Materializer.new(@account, strategy: :forward).materialize_holdings
    end
  end

  # A position that takes in a transfer has no cost basis this app can know.
  # A nil from the calculator alone left the previous calculated figure
  # standing — the stale number reporting a transferred coin as if it had been
  # bought on the day it arrived. `avg_cost` reads that stored value before it
  # ever reaches the transfer guard, so the guard was only protecting holdings
  # that had nothing stored at all.
  #
  # Materialised first and relabelled after, because that is the case that
  # matters: a position already carrying a figure worked out before anyone
  # knew the movement was a transfer.
  test "a transfer clears a cost basis this app had worked out" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: Date.current)
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings
    assert_equal 200, latest_holding.cost_basis.to_d, "nothing was stored to clear"

    @account.trades.each { |t| t.update!(investment_activity_label: Trade::TRANSFER_LABEL) }
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    assert_nil latest_holding.cost_basis, "the stale calculated figure survived the transfer"
    assert_nil latest_holding.cost_basis_source
    assert_nil latest_holding.avg_cost
  end

  test "a sweep in clears a cost basis this app had worked out" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: Date.current)
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings
    assert_equal 200, latest_holding.cost_basis.to_d

    @account.trades.each { |trade| trade.update!(investment_activity_label: "Sweep In") }
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    assert_nil latest_holding.cost_basis
    assert_nil latest_holding.cost_basis_source
    assert_nil latest_holding.avg_cost
  end

  # A row carrying a figure with no `cost_basis_source` was invisible to
  # `load_existing_holdings_map`, so the clearing above saw no existing holding
  # and left the stale basis standing — the rows least able to justify the
  # number they hold being the ones that kept it.
  test "a transfer clears a stored basis that never recorded where it came from" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: Date.current)
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    @account.holdings.where(security: @aapl).update_all(cost_basis: 200, cost_basis_source: nil)
    @account.trades.each { |t| t.update!(investment_activity_label: Trade::TRANSFER_LABEL) }
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    assert_nil latest_holding.cost_basis, "a source-less figure outlived the transfer"
  end
  # Somebody asserted what this position cost them, which is exactly what the
  # app cannot work out for a transfer. Theirs to keep.
  test "a transfer leaves a provider cost basis alone" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: Date.current)
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    @account.holdings.where(security: @aapl).update_all(cost_basis: 150, cost_basis_source: "provider")
    @account.trades.each { |t| t.update!(investment_activity_label: Trade::TRANSFER_LABEL) }
    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    assert_equal 150, latest_holding.cost_basis.to_d
  end

  # An ordinary purchase is untouched: the exclusion keys off the label, and
  # most rows carry none at all.
  test "an ordinary purchase still gets its calculated basis" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: Date.current)

    Holding::Materializer.new(@account, strategy: :forward).materialize_holdings

    assert_equal 200, latest_holding.cost_basis.to_d
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

  test "cleans up calculated holdings on earlier provider snapshot dates when the snapshot is in another currency" do
    [ Date.yesterday, Date.current ].each do |date|
      ExchangeRate.create!(from_currency: "EUR", to_currency: "USD", date: date, rate: 1.2)
    end

    coinstats_item = @family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(
      name: "Brokerage",
      currency: "USD"
    )
    account_provider = AccountProvider.create!(account: @account, provider: coinstats_account)

    [ Date.yesterday, Date.current ].each do |date|
      Holding.create!(
        account: @account,
        security: @aapl,
        qty: 10,
        price: 200,
        amount: 2000,
        currency: "EUR",
        date: date,
        account_provider: account_provider
      )
    end

    Holding::Materializer.new(@account, strategy: :reverse).materialize_holdings

    yesterday_holdings = @account.holdings.where(security: @aapl, date: Date.yesterday)

    assert_equal [ "EUR" ], yesterday_holdings.pluck(:currency)
    assert_equal [ account_provider.id ], yesterday_holdings.pluck(:account_provider_id)
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


  # A manual basis is set on one snapshot row, the latest one the drawer
  # shows. The next day's sync adds a new row for the same position, which
  # must carry the user's figure rather than the calculated one.
  test "a manual cost basis carries to the next day's row" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: 2.days.ago.to_date)
    materialize
    latest_holding.set_manual_cost_basis!(150)
    locked_date = latest_holding.date

    travel_to 1.day.from_now do
      materialize
      assert_operator latest_holding.date, :>, locked_date, "no new row was written, so nothing was tested"
      assert_equal 150, latest_holding.cost_basis.to_d, "the next day's row took the calculated figure"
      assert_equal "manual", latest_holding.cost_basis_source
      assert latest_holding.cost_basis_locked?
    end
  end

  # The case a manual basis exists for: a transferred-in position has no
  # basis this app can know, so the user supplies one.
  test "a manual cost basis on a transferred-in position carries to the next day's row" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: 2.days.ago.to_date)
    @account.trades.each { |t| t.update!(investment_activity_label: Trade::TRANSFER_LABEL) }
    materialize
    assert_nil latest_holding.avg_cost, "precondition: a transfer leaves the basis unknown"
    latest_holding.set_manual_cost_basis!(150)

    travel_to 1.day.from_now do
      materialize
      assert_equal 150, latest_holding.avg_cost&.amount, "the user's figure did not survive the next day's sync"
    end
  end

  # The locked per-share figure becomes the opening basis of the units held
  # on the locked date; a later buy blends in at its own price.
  test "a buy after a manual cost basis blends into the locked figure" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: 2.days.ago.to_date)
    materialize
    latest_holding.set_manual_cost_basis!(150)

    travel_to 1.day.from_now do
      create_trade(@aapl, account: @account, qty: 1, price: 200, date: Date.current)
      materialize
      assert_equal 2, latest_holding.qty, "precondition: the later buy is not on the latest row"
      assert_equal 175, latest_holding.cost_basis&.to_d, "expected (150 x 1 + 200 x 1) / 2"
      assert_not latest_holding.cost_basis_locked?, "a row the trades moved on from is the calculation's, not the user's"
    end
  end

  test "a buy after a manual cost basis on a transferred-in position blends into the locked figure" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: 2.days.ago.to_date)
    @account.trades.each { |t| t.update!(investment_activity_label: Trade::TRANSFER_LABEL) }
    materialize
    latest_holding.set_manual_cost_basis!(150)

    travel_to 1.day.from_now do
      create_trade(@aapl, account: @account, qty: 1, price: 200, date: Date.current)
      materialize
      assert_equal 175, latest_holding.avg_cost&.amount, "nil means the position went back to unknown"
    end
  end

  # A sell relieves units at the running basis, so the per-share figure stays
  # the user's, and the sale's realized gain is measured against it.
  test "a sell after a manual cost basis keeps the per-share figure" do
    create_trade(@aapl, account: @account, qty: 2, price: 200, date: 2.days.ago.to_date)
    materialize
    latest_holding.set_manual_cost_basis!(150)

    travel_to 1.day.from_now do
      sale = create_trade(@aapl, account: @account, qty: -1, price: 250, date: Date.current)
      materialize
      assert_equal 1, latest_holding.qty
      assert_equal 150, latest_holding.cost_basis&.to_d
      assert_equal 100, Trade.find(sale.entryable_id).realized_gain_loss&.value&.amount, "250 - 150, not 250 - 200"
    end
  end

  test "a full close and repurchase after a manual cost basis starts fresh" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: 3.days.ago.to_date)
    materialize
    @account.holdings.find_by!(security: @aapl, date: 3.days.ago.to_date).set_manual_cost_basis!(150)
    create_trade(@aapl, account: @account, qty: -1, price: 250, date: 2.days.ago.to_date)
    create_trade(@aapl, account: @account, qty: 1, price: 300, date: 1.day.ago.to_date)

    materialize

    assert_equal 300, latest_holding.cost_basis&.to_d
    assert_equal "calculated", latest_holding.cost_basis_source
  end

  test "the latest of two locked rows is the opening basis" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: 4.days.ago.to_date)
    materialize
    @account.holdings.find_by!(security: @aapl, date: 4.days.ago.to_date).set_manual_cost_basis!(150)
    @account.holdings.find_by!(security: @aapl, date: 2.days.ago.to_date).set_manual_cost_basis!(120)

    materialize

    assert_equal 120, latest_holding.cost_basis&.to_d
    assert_equal 150, @account.holdings.find_by!(security: @aapl, date: 3.days.ago.to_date).cost_basis&.to_d, "the first lock still covers the day between"
  end

  test "a transfer-in after a manual cost basis makes the position unknown" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: 2.days.ago.to_date)
    materialize
    latest_holding.set_manual_cost_basis!(150)

    travel_to 1.day.from_now do
      transfer = create_trade(@aapl, account: @account, qty: 1, price: 200, date: Date.current)
      transfer.trade.update!(investment_activity_label: Trade::TRANSFER_LABEL)
      materialize
      assert_nil latest_holding.avg_cost
    end
  end

  test "unlocking stops the carry-forward" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: 2.days.ago.to_date)
    materialize
    latest_holding.set_manual_cost_basis!(150)

    travel_to 1.day.from_now do
      materialize
      latest_holding.unlock_cost_basis!
      materialize
      assert_equal 200, latest_holding.cost_basis&.to_d, "an earlier locked row was still rolled forward"
      assert_equal "calculated", latest_holding.cost_basis_source
    end
  end

  test "rows dated before a manual cost basis keep their calculated figure" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: 3.days.ago.to_date)
    materialize
    before = @account.holdings.where(security: @aapl).where("date < ?", 1.day.ago.to_date).order(:date).pluck(:date, :cost_basis)
    @account.holdings.find_by!(security: @aapl, date: 1.day.ago.to_date).set_manual_cost_basis!(150)

    materialize

    assert_equal before, @account.holdings.where(security: @aapl).where("date < ?", 1.day.ago.to_date).order(:date).pluck(:date, :cost_basis)
  end

  test "a manual cost basis leaves another security in the account alone" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: 2.days.ago.to_date)
    create_trade(@msft, account: @account, qty: 1, price: 300, date: 2.days.ago.to_date)
    materialize
    latest_holding.set_manual_cost_basis!(150)

    travel_to 1.day.from_now do
      create_trade(@msft, account: @account, qty: 1, price: 300, date: Date.current)
      materialize
      msft = @account.holdings.where(security: @msft).order(:date).last
      assert_equal 300, msft.cost_basis&.to_d
      assert_equal "calculated", msft.cost_basis_source
    end
  end

  # A carried row is re-derived on every run: a trade later entered inside
  # the carried span moves the position on from that date, and the rows
  # after it are the calculation's, rolled forward from the user's figure.
  test "a trade entered inside a carried span ends the carry from its date" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: 4.days.ago.to_date)
    materialize
    @account.holdings.find_by!(security: @aapl, date: 4.days.ago.to_date).set_manual_cost_basis!(150)
    materialize
    assert latest_holding.cost_basis_carried?, "precondition: the lock was carried to today"

    create_trade(@aapl, account: @account, qty: 1, price: 200, date: 2.days.ago.to_date)
    materialize

    before_trade = @account.holdings.find_by!(security: @aapl, date: 3.days.ago.to_date)
    assert_equal [ 150, true, true ], [ before_trade.cost_basis.to_d, before_trade.cost_basis_locked?, before_trade.cost_basis_carried? ]
    assert_equal 175, latest_holding.cost_basis&.to_d, "a stale carried row re-seeded the user's figure over the blend"
    assert_not latest_holding.cost_basis_locked?
    assert_not latest_holding.cost_basis_carried?
  end

  test "only the row the user locked is their lock; the rows it is carried onto are marked carried" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: 3.days.ago.to_date)
    materialize
    locked = @account.holdings.find_by!(security: @aapl, date: 3.days.ago.to_date)
    locked.set_manual_cost_basis!(150)

    materialize

    assert_not locked.reload.cost_basis_carried?
    later = @account.holdings.where(security: @aapl).where("date > ?", locked.date)
    assert later.exists?
    assert later.all?(&:cost_basis_carried?)
  end

  test "setting a figure on a carried row makes it the user's own lock" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: 3.days.ago.to_date)
    materialize
    @account.holdings.find_by!(security: @aapl, date: 3.days.ago.to_date).set_manual_cost_basis!(150)
    materialize

    latest_holding.set_manual_cost_basis!(140)

    assert_not latest_holding.cost_basis_carried?
    assert latest_holding.cost_basis_locked?
  end

  # A later lock is the user's own statement about later units, and stays
  # when an earlier one is released.
  test "unlocking an earlier lock keeps a later one the user set" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: 4.days.ago.to_date)
    materialize
    first = @account.holdings.find_by!(security: @aapl, date: 4.days.ago.to_date)
    first.set_manual_cost_basis!(150)
    @account.holdings.find_by!(security: @aapl, date: 2.days.ago.to_date).set_manual_cost_basis!(120)
    materialize

    first.reload.unlock_cost_basis!
    assert @account.holdings.find_by!(security: @aapl, date: 1.day.ago.to_date).cost_basis_locked?, "the later lock's carried rows were released with the earlier one"
    materialize

    assert_equal 120, latest_holding.cost_basis&.to_d
    assert latest_holding.cost_basis_locked?
    assert_equal 200, @account.holdings.find_by!(security: @aapl, date: 3.days.ago.to_date).cost_basis&.to_d, "the released lock's carried rows went back to the calculation"
  end

  # Unlocking releases the rows the figure was carried onto with nothing in
  # its place, so a position the calculation cannot cost goes back to
  # unknown rather than keeping the user's figure unlocked.
  test "unlocking a transferred-in position's carried figure leaves it unknown" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: 3.days.ago.to_date)
    @account.trades.each { |t| t.update!(investment_activity_label: Trade::TRANSFER_LABEL) }
    materialize
    @account.holdings.find_by!(security: @aapl, date: 3.days.ago.to_date).set_manual_cost_basis!(150)
    materialize
    assert latest_holding.cost_basis_carried?, "precondition"

    latest_holding.unlock_cost_basis!
    materialize

    assert_nil latest_holding.avg_cost, "the user's figure stayed on a row nobody had locked"
    assert_nil @account.holdings.find_by!(security: @aapl, date: 2.days.ago.to_date).avg_cost
  end

  # The lock covers the units held at the end of its date, so a trade entered
  # on an earlier date changes what it covers, not whether it carries.
  test "a trade entered before the lock date keeps the carry in the same sync" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: 3.days.ago.to_date)
    materialize
    @account.holdings.find_by!(security: @aapl, date: 3.days.ago.to_date).set_manual_cost_basis!(150)
    materialize

    create_trade(@aapl, account: @account, qty: 1, price: 200, date: 4.days.ago.to_date)
    materialize

    assert_equal 2, latest_holding.qty
    assert latest_holding.cost_basis_carried?, "the carry compared against the lock row's quantity before this sync"
    assert_equal 150, latest_holding.cost_basis&.to_d
  end

  # Linked accounts rebuild their history backwards from the provider's
  # snapshot, with their own replay of the trades.
  test "a manual cost basis rolls forward on the reverse strategy too" do
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: 2.days.ago.to_date)
    create_trade(@aapl, account: @account, qty: 1, price: 200, date: Date.current)
    Holding.create!(account: @account, security: @aapl, qty: 2, price: 200, amount: 400, currency: "USD", date: Date.current)
    Holding::Materializer.new(@account, strategy: :reverse).materialize_holdings
    @account.holdings.find_by!(security: @aapl, date: 1.day.ago.to_date).set_manual_cost_basis!(150)

    Holding::Materializer.new(@account, strategy: :reverse).materialize_holdings

    assert_equal 175, @account.holdings.find_by!(security: @aapl, date: Date.current).cost_basis&.to_d
  end

  private

    def latest_holding
      @account.holdings.where(security: @aapl).order(:date).last
    end

    def materialize
      Holding::Materializer.new(@account.reload, strategy: :forward).materialize_holdings
    end
end
