require "test_helper"

class Insight::Generators::BalanceDiscrepancyGeneratorTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "flags a linked depository account with a real, persistent balance gap" do
    account = accounts(:connected) # Depository, linked via plaid_account fixture
    build_waypoints(account, [
      { type: "opening_anchor", date: 10.days.ago.to_date, balance: 1000 },
      { type: "reconciliation", date: 5.days.ago.to_date, balance: 1050 },
      { type: "reconciliation", date: 4.days.ago.to_date, balance: 1050 },
      { type: "reconciliation", date: 3.days.ago.to_date, balance: 1050 },
      { type: "reconciliation", date: 2.days.ago.to_date, balance: 1050 }
    ])

    insights = generate

    assert_equal 1, insights.size
    insight = insights.first
    assert_equal "balance_discrepancy", insight.insight_type
    assert_equal "high", insight.priority
    assert_equal account.id, insight.metadata[:account_id]
    assert_equal 50.0, insight.metadata[:difference]
    assert_equal 5.days.ago.to_date.to_s, insight.metadata[:since_date]
    assert_equal "balance_discrepancy:#{account.id}:#{5.days.ago.to_date}", insight.dedup_key
    # Money formatted in the account's own currency, not family currency.
    assert_equal Money.new(50, account.currency).format, insight.facts[:difference]
  end

  test "stores the account's own currency on the insight, not the family's" do
    account = accounts(:connected)
    account.update!(currency: "EUR")
    assert_not_equal @family.currency, account.currency, "test requires a genuine mismatch"
    build_waypoints(account, [
      { type: "opening_anchor", date: 10.days.ago.to_date, balance: 1000 },
      { type: "reconciliation", date: 5.days.ago.to_date, balance: 1050 },
      { type: "reconciliation", date: 4.days.ago.to_date, balance: 1050 },
      { type: "reconciliation", date: 3.days.ago.to_date, balance: 1050 },
      { type: "reconciliation", date: 2.days.ago.to_date, balance: 1050 }
    ])

    insight = generate.first

    assert insight, "expected a discrepancy to be detected"
    assert_equal "EUR", insight.currency
  end

  test "says nothing about an account with no gap" do
    account = accounts(:connected)
    build_waypoints(account, [
      { type: "opening_anchor", date: 10.days.ago.to_date, balance: 1000 },
      { type: "reconciliation", date: 3.days.ago.to_date, balance: 1000 }
    ])

    assert_empty generate
  end

  test "ignores manual (unlinked) accounts entirely" do
    account = @family.accounts.create!(
      name: "Manual Checking", accountable: Depository.new, currency: "USD",
      balance: 0, cash_balance: 0, status: "active"
    )
    build_waypoints(account, [
      { type: "opening_anchor", date: 10.days.ago.to_date, balance: 1000 },
      { type: "reconciliation", date: 5.days.ago.to_date, balance: 1050 },
      { type: "reconciliation", date: 4.days.ago.to_date, balance: 1050 },
      { type: "reconciliation", date: 3.days.ago.to_date, balance: 1050 }
    ])

    assert_empty generate
  end

  test "ignores account types outside Depository/CreditCard" do
    account = accounts(:investment)

    eligible = Insight::Generators::BalanceDiscrepancyGenerator.new(@family).send(:eligible_accounts)

    assert_not_includes eligible, account, "Investment is out of scope for v1 even if otherwise eligible"
  end

  test "ignores accounts with entries in a currency other than the account's own" do
    account = accounts(:connected)
    build_waypoints(account, [
      { type: "opening_anchor", date: 10.days.ago.to_date, balance: 1000 },
      { type: "reconciliation", date: 5.days.ago.to_date, balance: 1050 },
      { type: "reconciliation", date: 4.days.ago.to_date, balance: 1050 },
      { type: "reconciliation", date: 3.days.ago.to_date, balance: 1050 }
    ])
    account.entries.create!(
      name: "Foreign txn", date: 6.days.ago.to_date, amount: -10, currency: "EUR",
      entryable: Transaction.new
    )

    assert_empty generate
  end

  private
    def build_waypoints(account, waypoints)
      waypoints.each do |w|
        account.entries.create!(
          name: "Valuation", date: w[:date], amount: w[:balance], currency: account.currency,
          entryable: Valuation.new(kind: w[:type])
        )
      end
    end

    def generate
      Insight::Generators::BalanceDiscrepancyGenerator.new(@family).generate
    end
end
