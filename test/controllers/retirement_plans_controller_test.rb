require "test_helper"

class RetirementPlansControllerTest < ActionDispatch::IntegrationTest
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @other = users(:family_member)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    RetirementPlan.where(user: [ @user, @other ]).delete_all
    sign_in @user
    ensure_tailwind_build
  end

  test "a user without preview access is turned away from every planner page" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))

    [ retirement_plan_url, edit_retirement_plan_url ].each do |url|
      get url
      assert_redirected_to root_path
      assert_match(/preview/i, flash[:alert])
    end

    assert_no_difference "RetirementPlan.count" do
      patch retirement_plan_url, params: { retirement_plan: { end_age: "85" } }
    end
    assert_redirected_to root_path
  end

  test "a user with preview access sees the planner" do
    get retirement_plan_url

    assert_response :success
    assert_select "h1", text: I18n.t("retirement_plans.show.title")
  end

  test "the form opens on the defaults when nothing is saved" do
    get edit_retirement_plan_url

    assert_response :success
    assert_select "input[name='retirement_plan[safe_withdrawal_rate_percent]'][value='4.0']"
    assert_select "input[name='retirement_plan[expected_annual_return_percent]'][value='5.0']"
  end

  test "saving writes the signed-in user's plan, in fractions, and nobody else's" do
    others = RetirementPlan.create!(user: @other, safe_withdrawal_rate: BigDecimal("0.03"))

    assert_difference "RetirementPlan.count", 1 do
      patch retirement_plan_url, params: { retirement_plan: {
        safe_withdrawal_rate_percent: "3.5", expected_annual_return_percent: "6",
        savings_rate_percent: "", retirement_date: "2045-06-30"
      } }
    end

    plan = RetirementPlan.find_by!(user: @user)
    assert_equal [ BigDecimal("0.035"), BigDecimal("0.06"), nil, Date.new(2045, 6, 30) ],
                 plan.values_at(:safe_withdrawal_rate, :expected_annual_return, :savings_rate, :retirement_date)
    assert_equal BigDecimal("0.03"), others.reload.safe_withdrawal_rate
  end

  test "a user id in the request is ignored" do
    patch retirement_plan_url, params: { retirement_plan: { user_id: @other.id, safe_withdrawal_rate_percent: "5" } }

    assert_equal @user, RetirementPlan.find_by!(safe_withdrawal_rate: BigDecimal("0.05")).user
    assert_nil RetirementPlan.find_by(user: @other)
  end

  test "an invalid setting is refused and nothing is written" do
    [ { safe_withdrawal_rate_percent: "0" }, { savings_rate_percent: "abc" }, { end_age: "30" } ].each do |params|
      assert_no_difference "RetirementPlan.count" do
        patch retirement_plan_url, params: { retirement_plan: params }
      end
      assert_response :unprocessable_entity
    end
  end

  test "saving the planner settings stores them in their units and seeds the streams once" do
    account = @user.family.accounts.create!(owner: @user, accountable: Depository.new, name: "Seed checking", currency: "USD", balance: 1)
    create_transaction(account: account, date: Date.current.beginning_of_month - 1.month, amount: 2_000)

    patch retirement_plan_url, params: { retirement_plan: {
      birth_year: "1980", end_age: "85", inflation_rate_percent: "2.5", mode: "fire"
    } }
    plan = RetirementPlan.find_by!(user: @user)

    assert_equal [ 1980, 85, BigDecimal("0.025"), "fire" ], [ plan.birth_year, plan.end_age, plan.inflation_rate, plan.mode ]
    assert plan.streams.exists?(source: "seeded_living_costs")
    assert_no_difference "RetirementPlan::Stream.count" do
      patch retirement_plan_url, params: { retirement_plan: { end_age: "86" } }
    end
  end

  test "a failure while seeding leaves the settings unsaved too" do
    RetirementPlan.create!(user: @user, end_age: 90)
    RetirementPlan.any_instance.stubs(:seed_living_costs).raises(RuntimeError, "seeding failed")

    assert_raises(RuntimeError) do
      patch retirement_plan_url, params: { retirement_plan: { birth_year: "1980", end_age: "85" } }
    end

    plan = RetirementPlan.find_by!(user: @user)
    assert_equal [ nil, 90, nil ], [ plan.birth_year, plan.end_age, plan.streams_seeded_on ]
  end

  # A seeded plan skips seeding, so only the rollback stands between an
  # invalid change and a redirect.
  test "an invalid change to a seeded plan is refused and not saved" do
    RetirementPlan.create!(user: @user, end_age: 90, streams_seeded_on: Date.current)

    patch retirement_plan_url, params: { retirement_plan: { end_age: "30", birth_year: "1980" } }

    assert_response :unprocessable_entity
    assert_equal [ 90, nil ], RetirementPlan.find_by!(user: @user).values_at(:end_age, :birth_year)
  end
end
