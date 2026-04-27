require "test_helper"

class BudgetMonthlySurplusTest < ActiveSupport::TestCase
  setup do
    @budget = budgets(:one)
  end

  test "monthly_surplus is non-negative" do
    assert_operator @budget.monthly_surplus, :>=, 0
  end

  test "monthly_surplus equals actual_income minus actual_spending when positive" do
    @budget.stub(:actual_income, 5000) do
      @budget.stub(:actual_spending, 3000) do
        assert_equal 2000, @budget.monthly_surplus
      end
    end
  end

  test "monthly_surplus clamps to zero when overspent" do
    @budget.stub(:actual_income, 1000) do
      @budget.stub(:actual_spending, 2000) do
        assert_equal 0, @budget.monthly_surplus
      end
    end
  end

  test "monthly_surplus tolerates nil actual_income / actual_spending" do
    @budget.stub(:actual_income, nil) do
      @budget.stub(:actual_spending, nil) do
        assert_equal 0, @budget.monthly_surplus
      end
    end
  end
end
