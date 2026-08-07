require "test_helper"

class BudgetPlansControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    sign_in @user
    ensure_tailwind_build
  end

  test "new renders as a standalone page" do
    get new_budget_plan_url

    assert_response :success
    assert_select "form[action=?]", budget_plans_path
  end

  test "new renders inside the modal frame" do
    get new_budget_plan_url, headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_select "form[action=?]", budget_plans_path
  end

  test "create with no accounts builds an all-accounts plan" do
    assert_difference "BudgetPlan.count", 1 do
      post budget_plans_url, params: { budget_plan: { name: "Test Drive", account_ids: [ "" ] } }
    end

    plan = @family.budget_plans.find_by!(slug: "test-drive")
    assert_not plan.scoped?
    assert_redirected_to budget_path("test-drive-#{Budget.date_to_param(Date.current)}")
  end

  test "create with checked accounts scopes the plan" do
    account = accounts(:depository)

    post budget_plans_url, params: { budget_plan: { name: "Scoped", account_ids: [ "", account.id ] } }

    plan = @family.budget_plans.find_by!(slug: "scoped")
    assert_equal [ account.id ], plan.scoped_account_ids
  end

  test "create ignores accounts outside the user's accessible accounts" do
    foreign_account = Account.create!(
      family: families(:empty),
      accountable: Depository.new,
      name: "Foreign",
      status: "active",
      currency: "USD",
      balance: 0
    )

    post budget_plans_url, params: { budget_plan: { name: "Sneaky", account_ids: [ "", foreign_account.id ] } }

    plan = @family.budget_plans.find_by!(slug: "sneaky")
    assert_not plan.scoped?
  end

  test "create with a blank name re-renders the form" do
    assert_no_difference "BudgetPlan.count" do
      post budget_plans_url, params: { budget_plan: { name: "" } }
    end

    assert_response :unprocessable_entity
  end

  test "update renames the plan and replaces its accounts" do
    plan = budget_plans(:dylan_personal)
    plan.budget_plan_accounts.create!(account: accounts(:depository))
    other_account = accounts(:credit_card)

    patch budget_plan_url(plan), params: { budget_plan: { name: "Solo", account_ids: [ "", other_account.id ] } }

    plan.reload
    assert_equal "Solo", plan.name
    assert_equal "solo", plan.slug
    assert_equal [ other_account.id ], plan.scoped_account_ids
  end

  test "update with all boxes unchecked clears the account scope" do
    plan = budget_plans(:dylan_personal)
    plan.budget_plan_accounts.create!(account: accounts(:depository))

    patch budget_plan_url(plan), params: { budget_plan: { name: plan.name, account_ids: [ "" ] } }

    assert_not plan.reload.scoped?
  end

  test "destroy removes a non-default plan and its budgets" do
    plan = budget_plans(:dylan_personal)
    Budget.find_or_bootstrap(@family, start_date: Date.current, plan: plan)

    assert_difference "BudgetPlan.count", -1 do
      delete budget_plan_url(plan)
    end

    assert_redirected_to budgets_path
    assert_not Budget.exists?(budget_plan_id: plan.id)
  end

  test "destroy refuses the default plan" do
    plan = budget_plans(:dylan_default)

    assert_no_difference "BudgetPlan.count" do
      delete budget_plan_url(plan)
    end

    assert_redirected_to budgets_path
    assert flash[:alert].present?
  end

  test "cannot touch another family's plan" do
    foreign_plan = families(:empty).budget_plans.create!(name: "Foreign")

    patch budget_plan_url(foreign_plan), params: { budget_plan: { name: "Hacked" } }

    assert_response :not_found
    assert_equal "Foreign", foreign_plan.reload.name
  end
end
