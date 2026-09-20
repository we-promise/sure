require "test_helper"

class Holding::CurrentForInvestmentAccountsTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(
      name: "Investment",
      balance: 2100,
      currency: "USD",
      accountable: Investment.new
    )
  end

  test "returns the latest provider import day while preserving per-security price dates" do
    coinstats_item = @family.coinstats_items.create!(name: "CoinStats", api_key: "test-key")
    coinstats_account = coinstats_item.coinstats_accounts.create!(name: "Brokerage", currency: "USD")
    account_provider = AccountProvider.create!(account: @account, provider: coinstats_account)

    current_holding = create_holding("AAPL", date: Date.current, account_provider: account_provider)
    stale_holding = create_holding("STALE", date: 1.day.ago.to_date, account_provider: account_provider)
    older_price_current_holding = create_holding("MSFT", date: 1.day.ago.to_date, account_provider: account_provider)
    stale_holding.update_columns(created_at: 2.days.ago, updated_at: 2.days.ago)

    assert_equal [ current_holding.id, older_price_current_holding.id ].sort,
                 described_query.pluck(:id).sort
  end

  test "returns the latest holding per security for a manual account" do
    security = Security.create!(ticker: "AAPL", name: "Apple")
    create_holding_for_security(security, date: 2.days.ago.to_date, qty: 1)
    latest = create_holding_for_security(security, date: Date.current, qty: 2)

    assert_equal [ latest.id ], described_query.pluck(:id)
  end

  private
    def described_query
      Holding::CurrentForInvestmentAccounts.new([ @account.id ]).relation
    end

    def create_holding(ticker, date:, account_provider: nil)
      security = Security.create!(ticker: ticker, name: ticker)
      create_holding_for_security(security, date: date, account_provider: account_provider)
    end

    def create_holding_for_security(security, date:, qty: 1, account_provider: nil)
      @account.holdings.create!(
        security: security,
        date: date,
        qty: qty,
        price: 100,
        amount: qty * 100,
        currency: "USD",
        account_provider: account_provider
      )
    end
end
