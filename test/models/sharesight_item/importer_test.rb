require "test_helper"

class SharesightItem::ImporterTest < ActiveSupport::TestCase
  # A fake Provider::Sharesight with canned responses.
  class FakeProvider
    attr_reader :calls

    def initialize(portfolios:, reports: {}, cash_accounts: [], error: nil)
      @portfolios = portfolios
      @reports = reports
      @cash_accounts = cash_accounts
      @error = error
      @calls = []
    end

    def fetch_portfolios
      raise @error if @error

      @portfolios
    end

    def fetch_performance(portfolio_id)
      @calls << [ :performance, portfolio_id ]
      @reports.fetch(portfolio_id, {})
    end

    def fetch_trades(portfolio_id)
      @calls << [ :trades, portfolio_id ]
      [ { "id" => 1, "transaction_type" => "BUY", "transaction_date" => "2021-03-01" } ]
    end

    def fetch_payouts(portfolio_id, start_date:)
      @calls << [ :payouts, portfolio_id, start_date ]
      [ { "id" => 2 } ]
    end

    def fetch_cash_accounts
      @calls << [ :cash_accounts ]
      @cash_accounts
    end

    def fetch_cash_account_transactions(cash_account_id)
      @calls << [ :cash_transactions, cash_account_id ]
      [ { "id" => "#{cash_account_id}-1", "amount" => 10 } ]
    end
  end

  PORTFOLIOS = [
    { "id" => 42, "name" => "Shares", "currency_code" => "AUD", "inception_date" => "03 Feb 2021" },
    { "id" => 43, "name" => "US shares", "currency_code" => "USD" }
  ].freeze

  # Sharesight's value includes every cash account (converted to AUD).
  REPORT = {
    "value" => 15400.5,
    "holdings" => [ { "id" => 1, "quantity" => 100.0, "value" => 10500.0 }, { "id" => 2, "quantity" => 10.0, "value" => 4500.0 } ],
    "cash_accounts" => [
      { "id" => 7, "value" => 250.5, "currency" => { "code" => "AUD" } },
      { "id" => 8, "value" => 99.0, "currency" => { "code" => "USD" } }
    ]
  }.freeze

  setup do
    @family = families(:dylan_family)
    @item = @family.sharesight_items.create!(name: "Sharesight", client_id: "client-id", client_secret: "client-secret")
  end

  test "imports each portfolio's holdings value and same-currency cash, counting cash once" do
    provider = FakeProvider.new(portfolios: PORTFOLIOS, reports: { "42" => REPORT })

    import(provider)

    shares = @item.sharesight_accounts.find_by!(sharesight_account_id: "42")
    assert_equal [ "Shares", "AUD", BigDecimal("15250.5"), BigDecimal("250.5") ],
                 [ shares.name, shares.currency, shares.current_balance, shares.cash_balance ]
    assert_equal [ 1, 2 ], shares.raw_holdings_payload.map { |holding| holding["id"] }
    assert_equal "USD", @item.sharesight_accounts.find_by!(sharesight_account_id: "43").currency
    assert @item.reload.good?
  end

  test "only fetches activity for portfolios linked to an account" do
    provider = FakeProvider.new(portfolios: PORTFOLIOS, reports: { "42" => REPORT })
    import(provider)
    assert_empty provider.calls.reject { |call| call.first == :performance }

    link(@item.sharesight_accounts.find_by!(sharesight_account_id: "42"))
    provider = FakeProvider.new(
      portfolios: PORTFOLIOS,
      reports: { "42" => REPORT },
      cash_accounts: [
        { "id" => 7, "portfolio_id" => 42, "currency" => "AUD" },
        { "id" => 8, "portfolio_id" => 42, "currency" => "USD" },
        { "id" => 9, "portfolio_id" => 99, "currency" => "AUD" }
      ]
    )
    import(provider)

    shares = @item.sharesight_accounts.find_by!(sharesight_account_id: "42")
    assert_includes provider.calls, [ :payouts, "42", Date.new(2021, 2, 3) ]
    assert_equal [ [ :cash_transactions, 7 ] ], provider.calls.select { |call| call.first == :cash_transactions }
    assert_equal [ 1 ], shares.raw_trades_payload.map { |trade| trade["id"] }
    assert_equal [ { "id" => 2 } ], shares.raw_payouts_payload
    assert_equal [ { "id" => "7-1", "amount" => 10, "currency" => "AUD" } ], shares.raw_cash_transactions_payload
    assert_not provider.calls.include?([ :trades, "43" ])
  end

  test "payouts start at the first trade when Sharesight gives no inception date" do
    link(@item.sharesight_accounts.create!(name: "US shares", currency: "USD", sharesight_account_id: "43"))
    provider = FakeProvider.new(portfolios: PORTFOLIOS)

    import(provider)

    assert_includes provider.calls, [ :payouts, "43", Date.new(2021, 3, 1) ]
  end

  test "removes unlinked portfolios Sharesight no longer returns and keeps linked ones" do
    stale = @item.sharesight_accounts.create!(name: "Closed", currency: "AUD", sharesight_account_id: "1")
    linked = @item.sharesight_accounts.create!(name: "Sold down", currency: "AUD", sharesight_account_id: "2")
    link(linked)

    import(FakeProvider.new(portfolios: PORTFOLIOS))

    assert_not SharesightAccount.exists?(stale.id)
    assert SharesightAccount.exists?(linked.id)
  end

  test "rejected credentials mark the connection as needing an update" do
    provider = FakeProvider.new(portfolios: [], error: Provider::Sharesight::AuthenticationError.new("rejected"))

    assert_raises(Provider::Sharesight::AuthenticationError) { import(provider) }
    assert @item.reload.requires_update?
  end

  private

    def import(provider)
      SharesightItem::Importer.new(@item, provider: provider).import
    end

    def link(sharesight_account)
      account = @family.accounts.create!(
        name: sharesight_account.name,
        balance: 0,
        currency: sharesight_account.currency,
        accountable: Investment.new
      )
      sharesight_account.ensure_account_provider!(account)
    end
end
