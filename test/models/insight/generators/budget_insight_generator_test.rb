require "test_helper"

class Insight::Generators::BudgetInsightGeneratorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @category = @family.categories.create!(name: "Budget Test Cat", color: "#101010", lucide_icon: "circle")
    # Two months back so the fixture entries, dated in the real current month,
    # stay out of the budget. Day 6 is early: the month is far from half over.
    @today = (Date.current - 2.months).change(day: 6)
    @month = @today.beginning_of_month
  end

  # Fixed charges that land early fill the line on day 6, but nothing in it is
  # left to watch: the month's bills are paid and nothing else was spent.
  test "does not warn about a line filled by bills already paid" do
    budget_line(53)
    gym = create_bill(category: @category, amount: 47.98, name: "Gym", day: 3)
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

  private
    def generate
      Insight::Generators::BudgetInsightGenerator.new(@family).generate
    end

    def budget_line(amount)
      budget = @family.budgets.create!(
        start_date: @month, end_date: @month.end_of_month,
        budgeted_spending: amount, expected_income: amount * 2, currency: "USD"
      )
      budget.budget_categories.create!(category: @category, budgeted_spending: amount, currency: "USD")
    end

    def assert_near_limit(insights)
      assert_equal [ "budget_at_risk" ], insights.map(&:insight_type)
      assert_equal [ @category.id ], insights.first.metadata[:near_category_ids]
    end
end
