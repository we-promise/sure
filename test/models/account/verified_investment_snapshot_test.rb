require "test_helper"

class Account::VerifiedInvestmentSnapshotTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @account = @family.accounts.create!(name: "Brokerage", currency: "USD", balance: 100, accountable: Investment.new)
    @item = @family.simplefin_items.create!(name: "SimpleFIN", access_url: "https://example.com/access")
    @provider = @item.simplefin_accounts.create!(
      account_id: "brokerage", name: "Brokerage", currency: "USD", account_type: "investment", current_balance: 900
    )
    @link = AccountProvider.create!(account: @account, provider: @provider)
    @security = Security.create!(ticker: "VSI", offline: true)
    @position = { security_id: @security.id, qty: 2, price: 45, amount: 90, cost_basis: 30 }
    @publisher = Account::VerifiedInvestmentSnapshot.new(@account)
  end

  test "selects only the verified date and securities without altering existing ledger history" do
    stale = @account.holdings.create!(security: @security, account_provider: @link, date: Date.current - 1,
      currency: "USD", qty: 1, price: 30, amount: 30)
    publish

    h = @account.current_holdings.sole
    assert_equal Date.current, h.date
    assert_equal 2.to_d, h.qty
    assert_equal 30.to_d, h.avg_cost.amount
    assert_nil h.account_provider_id
    assert_equal [ h.id ], Holding::CurrentForInvestmentAccounts.new([ @account.id ]).relation.pluck(:id)
    assert_equal 1.to_d, stale.reload.qty
    assert_equal 100.to_d, @account.current_anchor_balance
    assert_equal Date.current, @account.current_anchor_date
    assert_equal 10.to_d, @account.balances.find_by!(date: Date.current).end_cash_balance
  end

  test "keeps the verified pair across balances-only and full SimpleFIN processing" do
    publish
    [ nil, [], [ { "id" => "partial", "symbol" => "VSI", "quantity" => "0", "market_value" => "25" } ] ].each do |payload|
      @provider.update!(raw_holdings_payload: payload)
      assert_no_changes -> { @account.holdings.order(:id).pluck(:id, :qty, :amount) } do
        SimplefinAccount::Investments::HoldingsProcessor.new(@provider).process
        SimplefinAccount::Processor.new(@provider).process
        Account::ProviderImportAdapter.new(@account).update_balance(balance: 1_200, cash_balance: 1_200, source: "simplefin")
        Balance::Materializer.new(@account, strategy: :reverse).materialize_balances
      end
      assert_equal [ 100.to_d, 10.to_d ], [ @account.reload.balance, @account.cash_balance ]
    end
  end

  test "rejects inconsistent, duplicate, future and competing observations atomically" do
    assert_no_difference [ "Holding.count", "Balance.count" ] do
      assert_raises(ArgumentError) { @publisher.publish!(date: Date.current, total: 500, cash: 10, positions: [ @position ]) }
      assert_raises(ArgumentError) { @publisher.publish!(date: Date.current, total: 190, cash: 10, positions: [ @position, @position ]) }
      assert_raises(ArgumentError) { publish(date: Date.current + 1) }
    end
    @account.holdings.create!(security: @security, account_provider: @link, date: Date.current, currency: "USD", qty: 1, price: 5, amount: 5)
    assert_raises(ArgumentError) { publish }
    assert_nil @account.reload.verified_investment_snapshot_date
  end

  test "a new snapshot can close a position; zero or unknown basis is not inferred" do
    publish(date: Date.current - 2, position: @position.merge(cost_basis: nil))
    assert_nil @account.current_holdings.sole.avg_cost
    publish(date: Date.current - 1, position: @position.merge(cost_basis: 0))
    assert_equal 0.to_d, @account.current_holdings.sole.avg_cost.amount

    @publisher.publish!(date: Date.current, total: 100, cash: 100, positions: [])
    assert_empty @account.current_holdings
    assert_empty Holding::CurrentForInvestmentAccounts.new([ @account.id ]).relation
    assert_equal 2, @account.holdings.count
  end

  test "does not apply the override to an unverified SimpleFIN investment" do
    SimplefinAccount::Processor.new(@provider).process
    assert_equal 900.to_d, @account.reload.balance
    assert_nil @account.verified_investment_snapshot_date
  end

  private

    def publish(date: Date.current, position: @position)
      @publisher.publish!(date: date, total: 100, cash: 10, positions: [ position ])
    end
end
