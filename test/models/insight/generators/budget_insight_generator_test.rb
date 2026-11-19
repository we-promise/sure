require "test_helper"

class Insight::Generators::BudgetInsightGeneratorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @category = @family.categories.create!(name: "Budget Test Cat", color: "#101010", lucide_icon: "circle")
    # The current month's household budget, for the shared-accounts tests.
    @budget = budgets(:one)
    # Two months back so the fixture entries, dated in the real current month,
    # stay out of the budget. Day 6 is early: the month is far from half over.
    @today = (Date.current - 2.months).change(day: 6)
    @month = @today.beginning_of_month
  end

  # Fixed charges that land early fill the line on day 6, but nothing in it is
  # left to watch: the month's bills are paid and nothing else was spent.
  test "does not warn about a line filled by bills already paid" do
    budget_line(50)
    gym = create_bill(category: @category, amount: 45, name: "Gym", day: 3)
    medical = create_bill(category: @category, amount: 5, name: "Medical plan", day: 5)

    travel_to @today do
      pay_bill(gym, date: @month.change(day: 3))
      pay_bill(medical, date: @month.change(day: 5))

      assert_empty generate
    end
  end

  # Rent takes 800 of a 1,000 line; 100 of other spending leaves half of the
  # remaining 200 free. The line is at 90%, but not near its limit.
  test "does not warn when bills account for most of a line near its limit" do
    budget_line(1_000)
    rent = create_bill(category: @category, amount: 800, name: "Rent", day: 3)

    travel_to @today do
      pay_bill(rent, date: @month.change(day: 3))
      create_transaction(category: @category, amount: 100, date: @month.change(day: 4))

      assert_empty generate
    end
  end

  test "warns when spending outside bills uses up what the bills leave" do
    budget_line(1_000)
    rent = create_bill(category: @category, amount: 800, name: "Rent", day: 3)

    travel_to @today do
      pay_bill(rent, date: @month.change(day: 3))
      create_transaction(category: @category, amount: 185, date: @month.change(day: 4))

      assert_near_limit generate
    end
  end

  test "warns about a line near its limit when it has no bills" do
    budget_line(100)

    travel_to @today do
      create_transaction(category: @category, amount: 95, date: @month.change(day: 4))

      assert_near_limit generate
    end
  end

  # 95 of 100 spent would be "near the limit", but the spend sits on
  # `connected`, private to family_admin. The shared feed must not report it.
  test "spending on an account private to one member does not put the budget at risk" do
    budget_category(@budget)
    create_transaction(category: @category, amount: 95, account: accounts(:connected), date: Date.current)

    assert_not_includes generated_types, "budget_at_risk"
  end

  test "spending on a shared account still puts the budget at risk" do
    budget_category(@budget)
    create_transaction(category: @category, amount: 95, date: Date.current)

    assert_includes generated_types, "budget_at_risk"
  end

  # With every account private, nothing is counted, so "on track" would only
  # mean that no shared spending exists.
  test "no budget insight when no account is visible to every member" do
    AccountShare.where(account: @family.accounts).delete_all
    budget_category(@budget)

    travel_to @budget.end_date do
      assert_empty generated_types
    end
  end

  # Shared but excluded from reports: IncomeStatement does not count it, so
  # the budget would again read zero spending as "on track".
  test "no budget insight when the only shared accounts are excluded from reports" do
    @family.accounts.accessible_by_all_active_members.update_all(exclude_from_reports: true)
    budget_category(@budget)

    travel_to @budget.end_date do
      assert_empty generated_types
    end
  end

  test "revoking a share changes the account digest of the insight" do
    budget_category(@budget)
    create_transaction(category: @category, amount: 95, date: Date.current)
    before = generated_digest

    account_shares(:credit_card_shared_with_member).destroy!

    assert_not_equal before, generated_digest
  end

  # A personal budget is visible to its owner and whoever they shared it with,
  # never to the whole family, so it must not reach the shared feed.
  test "a personal budget is not reported" do
    @budget.destroy!
    personal = @family.budgets.create!(
      user: users(:family_admin), start_date: Date.current.beginning_of_month,
      end_date: Date.current.end_of_month, budgeted_spending: 100, expected_income: 0, currency: "USD"
    )
    budget_category(personal)
    create_transaction(category: @category, amount: 95, date: Date.current)

    assert_empty generated_types
  end

  private
    def generate
      Insight::Generators::BudgetInsightGenerator.new(@family).generate
    end

    def generated_types
      generate.map(&:insight_type)
    end

    def generated_digest
      generate.first.metadata[:accounts_digest]
    end

    def budget_category(budget, amount = 100)
      budget.budget_categories.create!(category: @category, budgeted_spending: amount, currency: "USD")
    end

    def budget_line(amount)
      budget = @family.budgets.create!(
        start_date: @month, end_date: @month.end_of_month,
        budgeted_spending: amount, expected_income: amount * 2, currency: "USD"
      )
      budget_category(budget, amount)
    end

    def assert_near_limit(insights)
      assert_equal [ "budget_at_risk" ], insights.map(&:insight_type)
      assert_equal [ @category.id ], insights.first.metadata[:near_category_ids]
    end
end
