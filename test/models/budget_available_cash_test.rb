require "test_helper"

# Lot A3: cash on hand shown beside the plan, never folded into it.
class BudgetAvailableCashTest < ActiveSupport::TestCase
  setup do
    @family = families(:empty)
    @budget = Budget.find_or_bootstrap(@family, start_date: Date.current, user: nil)
    @budget.update!(budgeted_spending: 3_000, expected_income: 5_000)
  end

  test "counts only liquidity" do
    cash = depository(2_000)
    investment(9_000)

    assert_equal cash.balance.to_d, @budget.available_cash
  end

  test "leaves out accounts excluded from reports" do
    depository(2_000)
    depository(500).update!(exclude_from_reports: true)

    assert_equal 2_000, @budget.available_cash
  end

  test "subtracts what a goal has earmarked on those accounts" do
    account = depository(6_000)
    goal_on(account, earmark: 2_000)

    assert_equal 6_000, @budget.available_cash
    assert_equal 2_000, @budget.earmarked_for_goals
    assert_equal 4_000, @budget.free_cash
  end

  # A whole-account link reserves no fixed slice, so summing `allocated_amount`
  # would read it as zero while it actually claims the remainder.
  test "a whole-account link counts for what it really claims" do
    account = depository(6_000)
    goal_on(account, earmark: nil)

    assert_equal 6_000, @budget.earmarked_for_goals
    assert_equal 0, @budget.free_cash
  end

  # Goal::FUNDABLE_ACCOUNT_TYPES includes Investment. Subtracting an earmark
  # held on a brokerage account from a cash figure that never counted it would
  # show a "really free" amount too low, with nothing on the page to explain it.
  test "ignores an earmark held on an account the cash figure never counted" do
    depository(4_000)
    goal_on(investment(9_000), earmark: 5_000)

    assert_equal 4_000, @budget.available_cash
    assert_equal 0, @budget.earmarked_for_goals
    assert_equal 4_000, @budget.free_cash
  end

  test "a released goal has handed its money back" do
    account = depository(6_000)
    goal = goal_on(account, earmark: 2_000)

    goal.archive!

    assert_equal 0, Budget.find(@budget.id).earmarked_for_goals
  end

  test "free cash never reads as negative" do
    account = depository(1_000)
    goal_on(account, earmark: nil)
    goal_on(depository(500), earmark: nil)

    assert_operator Budget.find(@budget.id).free_cash, :>=, 0
  end

  # The whole point of the compromise: the plan is a forecast and stays one.
  test "none of this touches the allocation arithmetic" do
    before_allocated = @budget.allocated_spending
    before_available = @budget.available_to_allocate
    goal_on(depository(6_000), earmark: 2_000)

    reloaded = Budget.find(@budget.id)

    assert_equal before_allocated, reloaded.allocated_spending
    assert_equal before_available, reloaded.available_to_allocate
    assert_equal 3_000, reloaded.budgeted_spending
  end


  # --- Review follow-ups (#3179) ---

  # `available_cash` converts each balance into the budget currency, so an
  # earmark summed in the goal's own would be subtracted from a figure it does
  # not match: a fully earmarked EUR account reading as partly free.
  test "a foreign-currency earmark is converted before it is subtracted" do
    account = Account.create!(
      family: @family, accountable: Depository.new,
      name: "EUR pot", currency: "EUR", balance: 1_000
    )
    @family.goals.create!(
      name: "Trip", target_amount: 1_000, currency: "EUR"
    ) { |g| g.goal_accounts.build(account: account, allocated_amount: 1_000) }

    ExchangeRate.stubs(:find_or_fetch_rate).returns(OpenStruct.new(rate: 1.2))

    assert_equal 1_200, @budget.available_cash
    assert_equal 1_200, @budget.earmarked_for_goals
    assert_equal 0, @budget.free_cash, "none of a fully earmarked account is free"
  end

  # `ExchangeRate.find_rate` does not exist; every multi-currency family
  # opening the budget page hit a NoMethodError before the cash panel rendered.
  test "a foreign-currency account does not take the page down" do
    Account.create!(
      family: @family, accountable: Depository.new,
      name: "EUR pot", currency: "EUR", balance: 1_000
    )

    ExchangeRate.stubs(:find_or_fetch_rate).returns(OpenStruct.new(rate: 1.2))

    assert_equal 1_200, @budget.available_cash
  end

  # A missing rate leaves the amount as it stands rather than raising: a panel
  # wrong by the spread beats the whole budget page failing to render.
  test "a missing rate leaves the figure standing rather than raising" do
    Account.create!(
      family: @family, accountable: Depository.new,
      name: "EUR pot", currency: "EUR", balance: 1_000
    )

    ExchangeRate.stubs(:find_or_fetch_rate).returns(nil)

    assert_equal 1_000, @budget.available_cash
  end

  private
    def depository(balance)
      Account.create!(
        family: @family, accountable: Depository.new,
        name: "Cash #{SecureRandom.hex(4)}", currency: @family.currency, balance: balance
      )
    end

    def investment(balance)
      Account.create!(
        family: @family, accountable: Investment.new,
        name: "Brokerage #{SecureRandom.hex(4)}", currency: @family.currency, balance: balance
      )
    end

    def goal_on(account, earmark:)
      @family.goals.create!(
        name: "Goal #{SecureRandom.hex(4)}", target_amount: 10_000, currency: @family.currency
      ) { |g| g.goal_accounts.build(account: account, allocated_amount: earmark) }
    end
end
