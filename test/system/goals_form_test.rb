require "application_system_test_case"

# The goal form swaps the amount field's label between "Target amount" and
# "Target balance" as the kind changes. The label also carries the
# required-field asterisk, in a span of its own, so how that swap is made
# decides whether the asterisk survives it — and only a browser can say.
class GoalsFormTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    # Goals sit behind the preview gate; without it the visit redirects to the
    # dashboard and the form never renders.
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
  end

  test "the required asterisk survives the label swap" do
    visit new_goal_path

    # This first check is the one that bites: `refresh()` runs on connect, so a
    # swap that replaced the label's children has already wiped the asterisk by
    # the time the page is idle — on every goal form, one-off included, with
    # nothing to put it back.
    label = find(".form-field__label", text: I18n.t("goals.form.fields.target_amount"))
    assert label.has_css?("span", text: "*"),
           "the required marker was gone before anything was even clicked"

    choose I18n.t("goals.form.kinds.maintained.label")

    swapped = find(".form-field__label", text: I18n.t("goals.form.fields.target_balance"))
    assert swapped.has_css?("span", text: "*"),
           "the label swap deleted the required marker"
  end

  test "a months-of-expenses reserve can actually be created" do
    family = @user.family
    spending = family.accounts.create!(accountable: Depository.new, name: "Checking",
                                       currency: family.currency, balance: 0)
    6.times do |i|
      month = Date.current.prev_month.beginning_of_month - i.months
      spending.entries.create!(date: month + 5.days, name: "Bills", amount: 1_450,
                               currency: family.currency, entryable: Transaction.new)
    end
    savings = family.accounts.create!(accountable: Depository.new, name: "Savings",
                                      currency: family.currency, balance: 4_200)

    visit new_goal_path
    choose I18n.t("goals.form.kinds.maintained.label")
    select I18n.t("goals.form.target_modes.months_of_expenses"),
           from: I18n.t("goals.form.fields.target_mode")
    find("input[name='goal[target_months]']").fill_in(with: "6")
    fill_in I18n.t("goals.form.fields.name"), with: "Emergency fund E2E"
    check "goal_account_ids_#{savings.id}"

    # goal-kind disables the amount input in this mode: its figure is derived
    # server-side, not typed. goal-form's isValid() used to require it to hold
    # a positive number regardless, so the button stayed refused and the click
    # never reached the server — a months-of-expenses reserve could not be
    # created from the UI at all.
    click_on I18n.t("goals.form.create")

    assert_text I18n.t("goals.create.success")
    goal = Goal.find_by(name: "Emergency fund E2E")
    assert goal.present?, "the goal was never created — the submit was refused client-side"
    assert goal.target_amount.to_d.positive?, "the derived amount never made it in"
    assert_current_path goal_path(goal)
  end
end
