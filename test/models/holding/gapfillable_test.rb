require "test_helper"

class Holding::GapfillableTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(
      name: "Test",
      balance: 20000,
      cash_balance: 20000,
      currency: "USD",
      accountable: Investment.new
    )
    @security = securities(:aapl)
    provider = @family.coinstats_items.create!(name: "Provider", api_key: "test-key")
    provider_account = provider.coinstats_accounts.create!(name: "Account", currency: "USD")
    @account_provider = AccountProvider.create!(account: @account, provider: provider_account)
  end

  test "selects the latest snapshot on or before the date with a first-snapshot fallback" do
    first_snapshot = Holding.create!(
      account: @account,
      security: @security,
      date: Date.new(2025, 1, 1),
      qty: 1,
      price: 1,
      amount: 1,
      currency: "USD",
      account_provider: @account_provider,
      cash_equivalent: false
    )
    Holding.create!(
      account: @account,
      security: @security,
      date: Date.new(2025, 1, 5),
      qty: 1,
      price: 1,
      amount: 1,
      currency: "CAD",
      account_provider: @account_provider,
      cash_equivalent: true
    )
    Holding.create!(
      account: @account,
      security: @security,
      date: Date.new(2025, 1, 5),
      qty: 1,
      price: 1,
      amount: 1,
      currency: "USD",
      account_provider: @account_provider,
      cash_equivalent: false
    )
    Holding.create!(
      account: @account,
      security: @security,
      date: Date.new(2025, 1, 10),
      qty: 1,
      price: 1,
      amount: 1,
      currency: "USD",
      account_provider: @account_provider,
      cash_equivalent: true
    )

    snapshots = Holding.send(:provider_cash_equivalent_snapshots_for, [ first_snapshot ])

    results = [
      Date.new(2024, 12, 31),
      Date.new(2025, 1, 1),
      Date.new(2025, 1, 6),
      Date.new(2025, 1, 10),
      Date.new(2025, 1, 11)
    ].map do |date|
      Holding.send(
        :provider_cash_equivalent_for,
        snapshots,
        account_id: @account.id,
        security_id: @security.id,
        date: date
      )
    end

    assert_equal [ false, false, false, true, true ], results
  end

  test "keeps snapshot lookups independent across account and security groups" do
    snapshots = {
      [ 1, 1 ] => [ [ Date.new(2025, 1, 1), false ], [ Date.new(2025, 1, 5), true ] ],
      [ 1, 2 ] => [ [ Date.new(2025, 1, 2), true ], [ Date.new(2025, 1, 6), false ] ],
      [ 2, 1 ] => [ [ Date.new(2025, 1, 2), true ], [ Date.new(2025, 1, 6), false ] ]
    }

    results = [
      [ 1, 1, Date.new(2025, 1, 4) ],
      [ 1, 2, Date.new(2025, 1, 4) ],
      [ 2, 1, Date.new(2025, 1, 4) ],
      [ 1, 1, Date.new(2025, 1, 6) ],
      [ 1, 2, Date.new(2025, 1, 7) ],
      [ 2, 1, Date.new(2025, 1, 7) ]
    ].map do |account_id, security_id, date|
      Holding.send(
        :provider_cash_equivalent_for,
        snapshots,
        account_id: account_id,
        security_id: security_id,
        date: date
      )
    end

    assert_equal [ false, true, true, true, false, false ], results
  end
end
