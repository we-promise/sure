require "test_helper"

class RetirementPlans::StreamsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @other = users(:family_member)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    RetirementPlan.where(user: [ @user, @other ]).delete_all
    sign_in @user
    ensure_tailwind_build
  end

  test "a user without preview access is turned away from the streams" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))

    get new_retirement_plan_stream_url
    assert_redirected_to root_path

    assert_no_difference "RetirementPlan::Stream.count" do
      post retirement_plan_streams_url, params: { retirement_plan_stream: { kind: "expense", name: "x", annual_amount: 1 } }
    end
    assert_redirected_to root_path
  end

  test "a stream is added to the signed-in user's own plan, and listed on the planner" do
    assert_difference "RetirementPlan::Stream.count", 1 do
      post retirement_plan_streams_url, params: { retirement_plan_stream: {
        kind: "income", name: "State pension", annual_amount: "11000", start_year: "2047", indexed: "1"
      } }
    end
    assert_redirected_to retirement_plan_path

    stream = RetirementPlan.find_by!(user: @user).streams.sole
    assert_equal [ "income", BigDecimal("11000"), 2047, "manual" ], [ stream.kind, stream.annual_amount, stream.start_year, stream.source ]

    get retirement_plan_url
    assert_select "#retirement-plan-streams tr[data-stream-id='#{stream.id}']", text: /State pension/
  end

  test "a first stream that loses the race for the plan is added to the winner's" do
    winner = RetirementPlan.create!(user: @user)
    RetirementPlan.stubs(:for).returns(RetirementPlan.new(user: @user))

    assert_no_difference "RetirementPlan.count" do
      post retirement_plan_streams_url, params: { retirement_plan_stream: { kind: "expense", name: "Rent", annual_amount: "1000" } }
    end

    assert_redirected_to retirement_plan_path
    assert_equal [ "Rent" ], winner.streams.pluck(:name)
  end

  # A one-off is paid once, in its start year, so it shows that year alone.
  test "a one-off shows the year it is paid, and a recurring stream its span" do
    plan = RetirementPlan.create!(user: @user)
    one_off = plan.streams.create!(kind: "one_off", name: "New roof", annual_amount: 20_000, start_year: 2030, source: "manual")
    recurring = plan.streams.create!(kind: "expense", name: "Rent", annual_amount: 12_000, start_year: 2030, source: "manual")

    get retirement_plan_url

    assert_select "tr[data-stream-id='#{one_off.id}']", text: /#{Regexp.escape(I18n.t("retirement_plans.show.stream_once", year: 2030))}/
    assert_select "tr[data-stream-id='#{one_off.id}']", text: /#{Regexp.escape(I18n.t("retirement_plans.show.end_age"))}/, count: 0
    assert_select "tr[data-stream-id='#{recurring.id}']", text: /2030 to #{Regexp.escape(I18n.t("retirement_plans.show.end_age"))}/
  end

  # A one-off is paid once, so neither the form nor the planner calls its
  # amount yearly; a recurring stream says each year beside its span.
  test "an amount is not called yearly for a one-off" do
    get new_retirement_plan_stream_url
    assert_select "label", text: /a year/i, count: 0
    assert_select "p", text: I18n.t("retirement_plans.streams.form.annual_amount_hint")

    plan = RetirementPlan.create!(user: @user)
    one_off = plan.streams.create!(kind: "one_off", name: "New roof", annual_amount: 20_000, start_year: 2030, source: "manual")
    recurring = plan.streams.create!(kind: "expense", name: "Rent", annual_amount: 12_000, start_year: 2030, source: "manual")

    get retirement_plan_url

    assert_select "#retirement-plan-streams th", text: /a year/i, count: 0
    assert_select "tr[data-stream-id='#{one_off.id}']", text: /a year|each year/i, count: 0
    assert_select "tr[data-stream-id='#{recurring.id}']", text: /each year/i
  end

  # Each amount in its own currency, whole units, and the fixed tag only on
  # a stream that does not rise with inflation.
  test "the planner lists each stream's amount in its own currency, and tags fixed ones" do
    ExchangeRate.stubs(:provider).returns(nil)
    plan = RetirementPlan.create!(user: @user)
    rent = plan.streams.create!(kind: "expense", name: "Rent", annual_amount: 12_000, source: "manual")
    abroad = plan.streams.create!(kind: "expense", name: "Flat abroad", annual_amount: 10_000, currency: "EUR", source: "manual")
    loan = plan.streams.create!(kind: "expense", name: "Loan", annual_amount: 6_000, indexed: false, source: "manual")

    get retirement_plan_url

    { rent => "$12,000", abroad => "€10,000", loan => "$6,000" }.each do |stream, amount|
      assert_select "tr[data-stream-id='#{stream.id}'] td.privacy-sensitive", text: amount
    end
    fixed = I18n.t("retirement_plans.show.fixed")
    assert_select "tr[data-stream-id='#{loan.id}'] span", text: fixed
    [ rent, abroad ].each { |stream| assert_select "tr[data-stream-id='#{stream.id}'] span", text: fixed, count: 0 }
  end

  test "an invalid stream is refused and nothing is written, not even the plan" do
    assert_no_difference [ "RetirementPlan::Stream.count", "RetirementPlan.count" ] do
      post retirement_plan_streams_url, params: { retirement_plan_stream: { kind: "expense", name: "", annual_amount: "0" } }
    end

    assert_response :unprocessable_entity
  end

  test "another user's stream cannot be opened, changed or deleted" do
    others = RetirementPlan.create!(user: @other).streams.create!(kind: "expense", name: "Theirs", annual_amount: 5, source: "manual")

    get edit_retirement_plan_stream_url(others)
    assert_response :not_found
    patch retirement_plan_stream_url(others), params: { retirement_plan_stream: { annual_amount: "1" } }
    assert_response :not_found
    delete retirement_plan_stream_url(others)
    assert_response :not_found

    assert_equal BigDecimal("5"), others.reload.annual_amount
  end

  test "a user's own stream can be changed and deleted" do
    stream = RetirementPlan.create!(user: @user).streams.create!(kind: "expense", name: "Mine", annual_amount: 5, source: "manual")

    get edit_retirement_plan_stream_url(stream)
    assert_response :success

    patch retirement_plan_stream_url(stream), params: { retirement_plan_stream: { annual_amount: "7" } }
    assert_equal BigDecimal("7"), stream.reload.annual_amount

    patch retirement_plan_stream_url(stream), params: { retirement_plan_stream: { annual_amount: "0" } }
    assert_response :unprocessable_entity
    assert_equal BigDecimal("7"), stream.reload.annual_amount

    assert_difference "RetirementPlan::Stream.count", -1 do
      delete retirement_plan_stream_url(stream)
    end
  end
end
