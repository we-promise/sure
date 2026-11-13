require "test_helper"

class SnaptradeAccount::HoldingsProcessorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @snaptrade_account = snaptrade_accounts(:fidelity_401k)

    @account = @family.accounts.create!(
      name: "Test Investment",
      balance: 50000,
      cash_balance: 1000,
      currency: "USD",
      accountable: Investment.new
    )

    @snaptrade_account.ensure_account_provider!(@account)
    @snaptrade_account.reload
  end

  test "a held position stays on its security across syncs when the ticker has duplicate rows" do
    held = Security.create!(ticker: "DUPH", name: "Held row")
    # The row the ordered fallback would prefer, so only the held-position step keeps the holding on `held`.
    Security.create!(ticker: "DUPH", name: "Priced row", exchange_operating_mic: "XNYS", price_provider: "yahoo_finance")
    hold_position(held, date: 1.day.ago.to_date)

    # Rewriting the held row moves its tuple behind the other one, so an unordered lookup reads the other row first.
    held.update!(name: "Held row (renamed)")

    2.times do
      process_holdings(build_holding(symbol: "DUPH"))
      assert_equal [ held.id ], @account.holdings.where(date: Date.current).pluck(:security_id)
    end
  end

  test "a security created on one sync is the one the next sync resolves after a duplicate row appears" do
    process_holdings(build_holding(symbol: "DUPN"))
    created = Security.find_by!(ticker: "DUPN")

    # A second row for the ticker arrives later, for example from a CSV import.
    Security.create!(ticker: "DUPN", name: "Imported row", exchange_operating_mic: "XNYS", price_provider: "yahoo_finance")
    created.update!(name: "Created row (renamed)")

    # Age the first sync's holding so the next sync writes a new one.
    @account.holdings.where(date: Date.current).update_all(date: 1.day.ago.to_date)
    process_holdings(build_holding(symbol: "DUPN"))

    assert_equal [ created.id ], @account.holdings.where(date: Date.current).pluck(:security_id)
  end

  # Another provider on the same account holds the ticker today on another
  # row. SnapTrade's holding goes on the row for the exchange it reports, and
  # the other provider's holding keeps its quantity and its provider.
  test "a sync leaves another provider's holding of the same ticker alone" do
    item = @family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    other_provider = AccountProvider.create!(account: @account, provider: item.coinstats_accounts.create!(name: "Other provider", currency: "USD"))
    theirs = Security.create!(ticker: "DUPO", name: "Other provider's row")
    listed = Security.create!(ticker: "DUPO", name: "Listed row", exchange_operating_mic: "XNYS")
    theirs_holding = @account.holdings.create!(security: theirs, date: Date.current, qty: 3, price: 100, amount: 300,
                                               currency: "USD", account_provider: other_provider)

    process_holdings(build_holding(symbol: "DUPO").deep_merge("instrument" => { "exchange" => "XNYS" }))

    theirs_holding.reload
    assert_equal [ 3, other_provider.id ], [ theirs_holding.qty, theirs_holding.account_provider_id ]
    assert_equal 10, @account.holdings.find_by!(security: listed, date: Date.current).qty
  end

  test "an ambiguous fallback pick is logged against this connection" do
    older = Security.create!(ticker: "DUPF", name: "Dup F", exchange_operating_mic: "XNYS", price_provider: "yahoo_finance")
    Security.create!(ticker: "DUPF", name: "Dup F", exchange_operating_mic: "XNAS", price_provider: "yahoo_finance")

    assert_difference -> { DebugLogEntry.count }, 1 do
      process_holdings(build_holding(symbol: "DUPF"))
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal [ "SnaptradeAccount::HoldingsProcessor", @family, @snaptrade_account.account_provider ],
                 [ entry.source, entry.family, entry.account_provider ]
    assert_equal [ older.id ], @account.holdings.where(date: Date.current).pluck(:security_id)
  end

  # The import adapter carries a remap and a cost-basis lock forward to the
  # next day's row by finding the earlier row whose provider_security_id is
  # the security it is given, so a remapped position must be resolved to the
  # provider's original row, not the row the user moved it to.
  test "a same-ticker remap stays locked on the next day's holding" do
    original, listed = remap_to_listed_row("DUPR")

    process_holdings(build_holding(symbol: "DUPR"))

    today = @account.holdings.where(date: Date.current).to_a
    assert_equal [ listed.id ], today.map(&:security_id)
    assert today.first.security_locked?
    assert_equal original.id, today.first.provider_security_id
  end

  test "a remapped position's locked cost basis is carried to the next day's holding" do
    _original, listed = remap_to_listed_row("DUPC")
    @account.holdings.find_by!(date: 1.day.ago.to_date).set_manual_cost_basis!(BigDecimal("42"))

    process_holdings(build_holding(symbol: "DUPC").merge("average_purchase_price" => 90))

    today = @account.holdings.find_by!(date: Date.current)
    assert_equal listed, today.security
    assert today.cost_basis_locked?
    assert_equal BigDecimal("42"), today.cost_basis
  end

  # The provider's cost basis is written to the row the holding landed on.
  test "a remapped position's holding still takes the provider's cost basis" do
    _original, listed = remap_to_listed_row("DUPB")

    process_holdings(build_holding(symbol: "DUPB").merge("average_purchase_price" => 90))

    today = @account.holdings.find_by!(date: Date.current)
    assert_equal listed, today.security
    assert_equal BigDecimal("90"), today.cost_basis
    assert_equal "provider", today.cost_basis_source
  end

  # A remap to a row of another ticker: the position's holdings no longer
  # carry SnapTrade's ticker, so only the provider's original row links them.
  # A second row of the original ticker, preferred by the fallback order,
  # must not take the next day's holding.
  test "a remap to another ticker stays locked on the next day's holding" do
    process_holdings(build_holding(symbol: "DUPX"))
    original = Security.find_by!(ticker: "DUPX")
    Security.create!(ticker: "DUPX", name: "Priced row", exchange_operating_mic: "XNYS", price_provider: "yahoo_finance")
    other_ticker = Security.create!(ticker: "DUPY", name: "Other ticker", exchange_operating_mic: "XNAS")
    @account.holdings.where(date: Date.current).update_all(date: 1.day.ago.to_date)
    @account.holdings.find_by!(security: original).remap_security!(other_ticker)

    process_holdings(build_holding(symbol: "DUPX"))

    today = @account.holdings.where(date: Date.current).to_a
    assert_equal [ other_ticker.id ], today.map(&:security_id)
    assert today.first.security_locked?
    assert_equal original.id, today.first.provider_security_id
  end

  private
    # Yesterday's sync put the position on the row SnapTrade created; the
    # user then remapped it to a listed row of the same ticker.
    def remap_to_listed_row(ticker)
      process_holdings(build_holding(symbol: ticker))
      original = Security.find_by!(ticker: ticker)
      listed = Security.create!(ticker: ticker, name: "Listed row", exchange_operating_mic: "XNYS", price_provider: "yahoo_finance")
      @account.holdings.where(date: Date.current).update_all(date: 1.day.ago.to_date)
      @account.holdings.find_by!(security: original).remap_security!(listed)
      [ original, listed ]
    end

    def hold_position(security, date:)
      @account.holdings.create!(
        security: security,
        date: date,
        qty: 10,
        price: 100,
        amount: 1000,
        currency: "USD",
        account_provider_id: @snaptrade_account.account_provider&.id
      )
    end

    def process_holdings(*holdings)
      @snaptrade_account.update!(raw_holdings_payload: holdings)
      SnaptradeAccount::HoldingsProcessor.new(@snaptrade_account).process
    end

    def build_holding(symbol:, units: 10, price: 100)
      {
        "instrument" => { "symbol" => symbol, "description" => "#{symbol} Inc" },
        "units" => units,
        "price" => price,
        "currency" => { "code" => "USD" }
      }
    end
end
