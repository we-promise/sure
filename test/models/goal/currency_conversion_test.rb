require "test_helper"

class Goal::CurrencyConversionTest < ActiveSupport::TestCase
  include BalanceTestHelper
  setup do
    @family = families(:empty)
    ExchangeRate.stubs(:provider).returns(nil)
  end

  test "mixed balances and fixed earmarks are converted after native allocation" do
    usd = cash("USD", 500)
    eur = cash("EUR", 1_000)
    rate("EUR", "USD", 1.2)
    goal = goal_on("USD", [ [ usd, nil ], [ eur, 400 ] ])

    assert_equal 980, goal.current_balance
    assert_equal 400, goal.account_native_backing(eur).amount
    assert_equal 480, goal.account_backing(eur).amount
    assert_equal "USD", goal.account_backing(eur).currency.iso_code
    assert_equal 980, goal.market_value_money.amount
    assert_equal 480, goal.backing_within([ eur.id ])
    assert_equal 400, goal.backing_within([ eur.id ], currency: "EUR")
  end

  test "goals in different currencies share native earmarks without double counting" do
    eur = cash("EUR", 1_000)
    rate("EUR", "USD", 1.2)
    first = goal_on("USD", [ [ eur, 800 ] ])
    second = goal_on("EUR", [ [ eur, 800 ] ])

    assert_equal 600, first.current_balance
    assert_equal 500, second.current_balance
    assert_equal 1_000, first.account_native_backing(eur).amount + second.account_native_backing(eur).amount
  end

  test "whole-account exclusivity applies across goal currencies" do
    eur = cash("EUR", 100)
    goal_on("USD", [ [ eur, nil ] ])
    other = @family.goals.new(name: "Other", target_amount: 1_000, currency: "EUR")
    other.goal_accounts.build(account: eur)

    assert_not other.valid?
    assert other.errors.any?
  end

  test "missing rates exclude the unknown amount and report an incomplete total" do
    goal = goal_on("USD", [ [ cash("USD", 200), nil ], [ cash("EUR", 900), nil ] ])
    ExchangeRate.expects(:find_or_fetch_rate).with(from: "EUR", to: "USD", date: Date.current).once.returns(nil)

    assert_equal 200, goal.current_balance
    assert goal.currency_conversion_incomplete?
    assert_equal [ "EUR" ], goal.missing_exchange_rate_currencies.to_a
    assert_equal 200, goal.market_value_money.amount
    assert_equal 1, DebugLogEntry.where(category: "goal_currency_conversion").count
  end

  test "zero foreign balances do not need a rate" do
    goal = goal_on("USD", [ [ cash("EUR", 0), nil ] ])
    ExchangeRate.expects(:find_or_fetch_rate).never

    assert_equal 0, goal.current_balance
    assert_not goal.currency_conversion_incomplete?
  end

  test "pace uses the currency and rate of each transaction date" do
    eur = cash("EUR", 1_000)
    goal = goal_on("USD", [ [ eur, nil ] ])
    past = 20.days.ago.to_date
    rate("EUR", "USD", 1.1, date: past)
    rate("EUR", "USD", 1.5)
    eur.entries.create!(name: "Deposit", date: past, amount: -300, currency: "EUR", entryable: Transaction.new)
    eur.entries.create!(name: "Pending", date: past, amount: -900, currency: "EUR",
                        entryable: Transaction.new(extra: { plaid: { pending: true } }))

    assert_equal 110, goal.pace
    assert_equal 1_500, goal.current_balance
  end

  test "investment contributions are converted after excluding market gains" do
    eur = @family.accounts.create!(name: "EUR investments", accountable: Investment.new, currency: "EUR", balance: 1_000)
    goal = goal_on("USD", [ [ eur, nil ] ])
    goal.market_flows = { eur.id => 200 }
    rate("EUR", "USD", 1.2)

    assert goal.contributions_basis?
    assert_equal 960, goal.current_balance
    assert_equal 1_200, goal.market_value_money.amount
  end

  test "consumption releases a native earmark and credits goal-currency progress" do
    eur = cash("EUR", 1_000)
    goal = goal_on("USD", [ [ eur, 500 ] ])
    rate("EUR", "USD", 2)

    goal.consume!(200, account: eur)

    assert_equal 400, goal.goal_accounts.first.reload.allocated_amount
    assert_equal 200, goal.consumed_amount
    assert_equal 800, goal.current_balance
    assert_equal 1_000, goal.progress_amount
    assert_equal 1_000, eur.reload.balance
  end

  test "whole-account consumption caps the remaining earmark in native units" do
    eur = cash("EUR", 1_000)
    goal = goal_on("USD", [ [ eur, nil ] ], target: 2_000)
    rate("EUR", "USD", 2)

    goal.consume!(200, account: eur)

    assert_equal 900, goal.goal_accounts.first.reload.allocated_amount
    assert_equal 2_000, goal.progress_amount
  end

  test "missing consumption rates cannot change progress or earmarks" do
    eur = cash("EUR", 1_000)
    goal = goal_on("USD", [ [ eur, 500 ] ])

    error = assert_raises(Goal::ConsumptionRefused) { goal.consume!(100, account: eur) }

    assert_equal :missing_exchange_rate, error.reason
    assert_equal 0, goal.reload.consumed_amount
    assert_equal 500, goal.goal_accounts.first.allocated_amount
  end

  test "pledges match a foreign deposit using the entry date exchange rate" do
    eur = cash("EUR", 100)
    goal = goal_on("USD", [ [ eur, nil ] ])
    pledge = goal.goal_pledges.create!(account: eur, amount: 120, kind: "transfer")
    rate("EUR", "USD", 1.2)
    entry = eur.entries.create!(name: "Deposit", date: Date.current, amount: -100, currency: "EUR", entryable: Transaction.new)

    assert pledge.matches?(entry)
    entry.amount = -120
    assert_not pledge.matches?(entry), "120 EUR must not be matched as 120 USD"
  end

  test "missing pledge rates do not produce false matches" do
    eur = cash("EUR", 100)
    goal = goal_on("USD", [ [ eur, nil ] ])
    pledge = goal.goal_pledges.create!(account: eur, amount: 100, kind: "transfer")
    entry = eur.entries.create!(name: "Deposit", date: Date.current, amount: -100, currency: "EUR", entryable: Transaction.new)

    assert_not pledge.matches?(entry)
    assert pledge.status_open?
  end

  test "budget cash reservations convert directly into budget currency" do
    eur = cash("EUR", 1_000)
    usd = cash("USD", 500)
    goal_on("GBP", [ [ eur, 400 ], [ usd, 200 ] ])
    rate("EUR", "USD", 1.2)
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current)

    assert_equal 1_700, budget.available_cash
    assert_equal 680, budget.earmarked_for_goals
    assert_equal 1_020, budget.free_cash
  end

  test "converted projection history meets the allocated current balance" do
    usd = cash("USD", 500)
    eur = cash("EUR", 1_000)
    rate("EUR", "USD", 1.2)
    goal = goal_on("USD", [ [ usd, nil ], [ eur, 400 ] ])
    create_balance(account: usd, date: Date.current, balance: 500)
    create_balance(account: eur, date: Date.current, balance: 1_000)

    assert_in_delta 980, goal.projection_payload[:saved_series].last[:value], 0.01
  end

  test "funding rows preserve native values while converting dated inflows" do
    eur = cash("EUR", 1_000)
    goal = goal_on("USD", [ [ eur, 400 ] ])
    past = 20.days.ago.to_date
    rate("EUR", "USD", 1.1, date: past)
    rate("EUR", "USD", 1.2)
    eur.entries.create!(name: "Deposit", date: past, amount: -100, currency: "EUR", entryable: Transaction.new)
    row = Goals::FundingAccountsBreakdownComponent.new(goal: goal).rows.first

    assert_equal 480, row[:backing_money].amount
    assert_equal "USD", row[:backing_money].currency.iso_code
    assert_equal 400, row[:native_backing_money].amount
    assert_equal "EUR", row[:balance_money].currency.iso_code
    assert_equal 110, row[:last_30_money].amount
  end

  test "completion freezes the converted balance" do
    eur = cash("EUR", 1_000)
    goal = goal_on("USD", [ [ eur, nil ] ])
    rate("EUR", "USD", 1.2)

    assert goal.complete!
    assert_equal 1_200, goal.reload.completed_amount
    eur.update!(balance: 0)
    assert_equal 1_200, Goal.find(goal.id).current_balance
  end

  test "missing rates cannot freeze a partial completion balance" do
    goal = goal_on("USD", [ [ cash("EUR", 1_000), nil ] ])

    assert_not goal.complete!
    assert goal.reload.active?
    assert_nil goal.completed_amount
  end

  private
    def cash(currency, balance)
      @family.accounts.create!(name: "#{currency} #{SecureRandom.hex(3)}", accountable: Depository.new,
                               currency: currency, balance: balance)
    end

    def goal_on(currency, accounts, target: 5_000)
      @family.goals.create!(name: "Mixed goal", target_amount: target, currency: currency) do |goal|
        accounts.each { |account, amount| goal.goal_accounts.build(account: account, allocated_amount: amount) }
      end
    end

    def rate(from, to, value, date: Date.current)
      ExchangeRate.create!(from_currency: from, to_currency: to, rate: value, date: date)
    end
end
