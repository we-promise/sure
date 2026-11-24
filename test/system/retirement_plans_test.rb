require "application_system_test_case"

# The planner's critical paths in a browser: the settings modal, and a
# stream added from its own modal.
class RetirementPlansTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true), show_ai_sidebar: false)
    RetirementPlan.where(user: @user).delete_all
    sign_in @user
  end

  test "a user sets up a plan from the planner's settings" do
    visit retirement_plan_path

    assert_selector "[data-planner-needs='birth_year']"

    click_link I18n.t("retirement_plans.show.settings"), match: :first
    within("dialog") do
      fill_in "retirement_plan[birth_year]", with: "1985"
      find("input[name='retirement_plan[retirement_date]']").set(Date.new(2045, 1, 1))
      click_button I18n.t("retirement_plans.form.save")
    end

    assert_selector "#retirement-planner-table tr[data-year='2045'][data-retired]"
    assert_selector "[data-planner-outcome]"
  end

  # The browser's own checks would stop the value first, so they are switched
  # off to reach the server's refusal.
  test "a refused setting is shown in the modal, over the planner" do
    visit retirement_plan_path
    click_link I18n.t("retirement_plans.show.settings"), match: :first

    within("dialog") do
      page.execute_script("document.querySelector('dialog form').noValidate = true")
      fill_in "retirement_plan[end_age]", with: "30"
      click_button I18n.t("retirement_plans.form.save")
    end

    assert_selector "dialog input[name='retirement_plan[end_age]'][value='30']"
    assert_selector "h1", text: I18n.t("retirement_plans.show.title")
    assert_equal 90, RetirementPlan.find_by(user: @user)&.end_age || 90
  end

  test "a refused stream is shown in the modal, over the planner" do
    RetirementPlan.create!(user: @user, birth_year: 1985, retirement_date: Date.new(2045, 1, 1), streams_seeded_on: Date.current)
    visit retirement_plan_path
    click_link I18n.t("retirement_plans.show.add_stream")

    within("dialog") do
      page.execute_script("document.querySelector('dialog form').noValidate = true")
      fill_in "retirement_plan_stream[name]", with: "Nothing"
      fill_in "retirement_plan_stream[annual_amount]", with: "0"
      click_button I18n.t("retirement_plans.streams.form.save")
    end

    assert_selector "dialog input[name='retirement_plan_stream[name]'][value='Nothing']"
    assert_selector "h1", text: I18n.t("retirement_plans.show.title")
    assert_equal 0, RetirementPlan.find_by!(user: @user).streams.count
  end

  test "a user adds a pension from its own modal" do
    RetirementPlan.create!(user: @user, birth_year: 1985, retirement_date: Date.new(2045, 1, 1), streams_seeded_on: Date.current)
    visit retirement_plan_path

    click_link I18n.t("retirement_plans.show.add_stream")
    within("dialog") do
      select I18n.t("retirement_plans.streams.form.kinds.income"), from: "retirement_plan_stream[kind]"
      fill_in "retirement_plan_stream[name]", with: "Pension"
      fill_in "retirement_plan_stream[annual_amount]", with: "12000"
      fill_in "retirement_plan_stream[start_year]", with: "2052"
      click_button I18n.t("retirement_plans.streams.form.save")
    end

    assert_selector "#retirement-plan-streams", text: "Pension"
    assert_equal 2052, RetirementPlan.find_by!(user: @user).streams.find_by!(name: "Pension").start_year
  end

  # A one-off is paid once, in its start year, so the form hides its To year
  # and leaves one typed before the kind changed out of the submission; the
  # model would otherwise refuse an end before the start over a field the plan
  # never reads.
  test "a one-off saves without the To year typed before its kind changed" do
    RetirementPlan.create!(user: @user, birth_year: 1985, retirement_date: Date.new(2045, 1, 1), streams_seeded_on: Date.current)
    visit retirement_plan_path

    click_link I18n.t("retirement_plans.show.add_stream")
    within("dialog") do
      fill_in "retirement_plan_stream[name]", with: "New roof"
      fill_in "retirement_plan_stream[annual_amount]", with: "20000"
      fill_in "retirement_plan_stream[start_year]", with: "2030"
      fill_in "retirement_plan_stream[end_year]", with: "2020"
      select I18n.t("retirement_plans.streams.form.kinds.one_off"), from: "retirement_plan_stream[kind]"
      assert_no_selector "input[name='retirement_plan_stream[end_year]']"
      click_button I18n.t("retirement_plans.streams.form.save")
    end

    assert_selector "#retirement-plan-streams", text: "New roof"
    stream = RetirementPlan.find_by!(user: @user).streams.find_by!(name: "New roof")
    assert_equal [ "one_off", 2030, nil ], [ stream.kind, stream.start_year, stream.end_year ]
  end

  test "spending keeps the To year it is given" do
    RetirementPlan.create!(user: @user, birth_year: 1985, retirement_date: Date.new(2045, 1, 1), streams_seeded_on: Date.current)
    visit retirement_plan_path

    click_link I18n.t("retirement_plans.show.add_stream")
    within("dialog") do
      select I18n.t("retirement_plans.streams.form.kinds.expense"), from: "retirement_plan_stream[kind]"
      fill_in "retirement_plan_stream[name]", with: "Mortgage"
      fill_in "retirement_plan_stream[annual_amount]", with: "18000"
      fill_in "retirement_plan_stream[end_year]", with: "2041"
      click_button I18n.t("retirement_plans.streams.form.save")
    end

    assert_selector "#retirement-plan-streams", text: "Mortgage"
    assert_equal 2041, RetirementPlan.find_by!(user: @user).streams.find_by!(name: "Mortgage").end_year
  end

  # Switching to one-off and back must not lose a To year already typed.
  test "spending keeps its To year after a switch to one-off and back" do
    RetirementPlan.create!(user: @user, birth_year: 1985, retirement_date: Date.new(2045, 1, 1), streams_seeded_on: Date.current)
    visit retirement_plan_path

    click_link I18n.t("retirement_plans.show.add_stream")
    within("dialog") do
      select I18n.t("retirement_plans.streams.form.kinds.expense"), from: "retirement_plan_stream[kind]"
      fill_in "retirement_plan_stream[name]", with: "Mortgage"
      fill_in "retirement_plan_stream[annual_amount]", with: "18000"
      fill_in "retirement_plan_stream[end_year]", with: "2041"
      select I18n.t("retirement_plans.streams.form.kinds.one_off"), from: "retirement_plan_stream[kind]"
      select I18n.t("retirement_plans.streams.form.kinds.expense"), from: "retirement_plan_stream[kind]"
      click_button I18n.t("retirement_plans.streams.form.save")
    end

    assert_selector "#retirement-plan-streams", text: "Mortgage"
    assert_equal 2041, RetirementPlan.find_by!(user: @user).streams.find_by!(name: "Mortgage").end_year
  end
end
