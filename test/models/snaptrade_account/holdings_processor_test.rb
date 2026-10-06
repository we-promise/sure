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

  private

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
