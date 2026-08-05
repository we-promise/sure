require "test_helper"

class BudgetPlanTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
  end

  test "requires a name" do
    plan = @family.budget_plans.new(name: "")
    assert_not plan.valid?
    assert plan.errors[:name].any?
  end

  test "generates slug from name" do
    plan = @family.budget_plans.create!(name: "Joint Accounts")
    assert_equal "joint-accounts", plan.slug
  end

  test "uniquifies slug within the family" do
    @family.budget_plans.create!(name: "Joint")
    second = @family.budget_plans.create!(name: "Joint!")
    assert_equal "joint-2", second.slug
  end

  test "same slug is allowed across families" do
    @family.budget_plans.create!(name: "Joint")
    other = families(:empty).budget_plans.create!(name: "Joint")
    assert_equal "joint", other.slug
  end

  test "month-shaped names get a -plan suffix so they cannot shadow month params" do
    plan = @family.budget_plans.create!(name: "Jan 2025")
    assert_equal "jan-2025-plan", plan.slug
  end

  test "names that parameterize to blank fall back to plan" do
    plan = @family.budget_plans.create!(name: "!!!")
    assert_equal "plan", plan.slug
  end

  test "slug regenerates on rename" do
    plan = @family.budget_plans.create!(name: "Joint")
    plan.update!(name: "Household")
    assert_equal "household", plan.slug
  end

  test "save retries with a fresh slug after losing the unique-index race" do
    @family.budget_plans.create!(name: "Joint")

    # Simulate the race: the loser computed "joint" before the winner's row
    # was visible, so neither the existence check nor the uniqueness
    # validation caught it and the INSERT hits the unique index.
    loser = @family.budget_plans.new(name: "Joint", slug: "joint")
    assert loser.save(validate: false)
    assert_equal "joint-2", loser.slug
  end

  test "cannot destroy the default plan" do
    plan = budget_plans(:dylan_default)
    assert_not plan.destroy
    assert plan.errors[:base].any?
    assert BudgetPlan.exists?(plan.id)
  end

  test "only one default plan per family" do
    assert_raises ActiveRecord::RecordNotUnique do
      @family.budget_plans.create!(name: "Another Default", is_default: true)
    end
  end

  test "scoped accounts must belong to the family" do
    plan = @family.budget_plans.new(name: "Joint")
    foreign_account = Account.create!(
      family: families(:empty),
      accountable: Depository.new,
      name: "Foreign",
      status: "active",
      currency: "USD",
      balance: 0
    )
    plan.budget_plan_accounts.build(account: foreign_account)

    assert_not plan.valid?
    assert plan.errors[:accounts].any?
  end

  test "scoped_account_ids is nil when no accounts are linked" do
    plan = @family.budget_plans.create!(name: "Everything")
    assert_not plan.scoped?
    assert_nil plan.scoped_account_ids
  end

  test "scoped_account_ids returns linked account ids" do
    account = accounts(:depository)
    plan = @family.budget_plans.create!(name: "Scoped")
    plan.budget_plan_accounts.create!(account: account)

    assert plan.scoped?
    assert_equal [ account.id ], plan.scoped_account_ids
  end

  test "destroying a plan destroys its budgets and account links" do
    plan = @family.budget_plans.create!(name: "Doomed")
    plan.budget_plan_accounts.create!(account: accounts(:depository))
    budget = Budget.find_or_bootstrap(@family, start_date: Date.current, plan: plan)

    assert_difference [ "Budget.count", "BudgetPlanAccount.count" ], -1 do
      plan.destroy!
    end
    assert_not Budget.exists?(budget.id)
  end

  test "default_budget_plan finds the existing default" do
    assert_equal budget_plans(:dylan_default), @family.default_budget_plan
  end

  test "default_budget_plan lazily creates one for families without plans" do
    family = families(:empty)
    assert_equal 0, family.budget_plans.count

    plan = family.default_budget_plan
    assert plan.is_default?
    assert_equal "Primary", plan.name
    assert_equal plan, family.default_budget_plan
    assert_equal 1, family.budget_plans.count
  end
  test "budget plan account rejects direct creation with another family's account" do
    foreign_account = Account.create!(
      family: families(:empty),
      accountable: Depository.new,
      name: "Foreign",
      status: "active",
      currency: "USD",
      balance: 0
    )

    budget_plan_account = BudgetPlanAccount.new(budget_plan: budget_plans(:dylan_default), account: foreign_account)

    assert_not budget_plan_account.valid?
    assert budget_plan_account.errors[:account].any?
  end
end
