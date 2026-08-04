# frozen_string_literal: true

require "test_helper"

class Api::V1::BudgetPlansControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family

    @user.api_keys.active.destroy_all

    @read_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "test_read_#{SecureRandom.hex(8)}"
    )

    @read_write_key = ApiKey.create!(
      user: @user,
      name: "Test Read Write Key",
      scopes: [ "read_write" ],
      source: "web",
      display_key: "test_rw_#{SecureRandom.hex(8)}"
    )
  end

  test "index requires authentication" do
    get api_v1_budget_plans_url

    assert_response :unauthorized
  end

  test "index lists the family's plans, default first" do
    get api_v1_budget_plans_url, headers: read_headers

    assert_response :success
    plans = JSON.parse(response.body)
    assert_equal @family.budget_plans.count, plans.length
    assert plans.first["is_default"]
    assert_includes plans.map { |p| p["slug"] }, "personal"
  end

  test "show returns a plan with its account ids" do
    plan = budget_plans(:dylan_personal)
    account = accounts(:depository)
    plan.budget_plan_accounts.create!(account: account)

    get api_v1_budget_plan_url(plan), headers: read_headers

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal plan.name, body["name"]
    assert_equal [ account.id ], body["account_ids"]
  end

  test "show 404s for another family's plan" do
    foreign_plan = families(:empty).budget_plans.create!(name: "Foreign")

    get api_v1_budget_plan_url(foreign_plan), headers: read_headers

    assert_response :not_found
  end

  test "create requires read_write scope" do
    post api_v1_budget_plans_url, params: { budget_plan: { name: "Joint" } }, headers: read_headers, as: :json

    assert_response :forbidden
  end

  test "create builds an unscoped plan from a name" do
    assert_difference "BudgetPlan.count", 1 do
      post api_v1_budget_plans_url, params: { budget_plan: { name: "Joint" } }, headers: read_write_headers, as: :json
    end

    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "joint", body["slug"]
    assert_equal [], body["account_ids"]
    assert_not body["is_default"]
  end

  test "create with account_ids scopes the plan" do
    account = accounts(:depository)

    post api_v1_budget_plans_url,
         params: { budget_plan: { name: "Scoped", account_ids: [ account.id ] } },
         headers: read_write_headers, as: :json

    assert_response :created
    assert_equal [ account.id ], JSON.parse(response.body)["account_ids"]
  end

  test "create rejects unknown or foreign account ids" do
    foreign_account = Account.create!(
      family: families(:empty),
      accountable: Depository.new,
      name: "Foreign",
      status: "active",
      currency: "USD",
      balance: 0
    )

    assert_no_difference "BudgetPlan.count" do
      post api_v1_budget_plans_url,
           params: { budget_plan: { name: "Sneaky", account_ids: [ foreign_account.id ] } },
           headers: read_write_headers, as: :json
    end

    assert_response :unprocessable_entity
    assert_match foreign_account.id, JSON.parse(response.body)["error"]
  end

  test "update renames a plan and regenerates its slug" do
    plan = budget_plans(:dylan_personal)

    patch api_v1_budget_plan_url(plan), params: { budget_plan: { name: "Solo" } }, headers: read_write_headers, as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "Solo", body["name"]
    assert_equal "solo", body["slug"]
  end

  test "update with empty account_ids clears the scope, omitting the key leaves it" do
    plan = budget_plans(:dylan_personal)
    plan.budget_plan_accounts.create!(account: accounts(:depository))

    patch api_v1_budget_plan_url(plan), params: { budget_plan: { name: "Personal" } }, headers: read_write_headers, as: :json
    assert_response :success
    assert plan.reload.scoped?

    patch api_v1_budget_plan_url(plan), params: { budget_plan: { name: "Personal", account_ids: [] } }, headers: read_write_headers, as: :json
    assert_response :success
    assert_not plan.reload.scoped?
  end

  test "destroy removes a non-default plan" do
    plan = budget_plans(:dylan_personal)

    assert_difference "BudgetPlan.count", -1 do
      delete api_v1_budget_plan_url(plan), headers: read_write_headers
    end

    assert_response :no_content
  end

  test "destroy refuses the default plan" do
    plan = budget_plans(:dylan_default)

    assert_no_difference "BudgetPlan.count" do
      delete api_v1_budget_plan_url(plan), headers: read_write_headers
    end

    assert_response :unprocessable_entity
  end

  private

    def read_headers
      { "X-Api-Key" => @read_key.plain_key }
    end

    def read_write_headers
      { "X-Api-Key" => @read_write_key.plain_key }
    end
end
