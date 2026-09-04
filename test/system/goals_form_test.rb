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

  # A reserve has no finish line to project: its date field is hidden and the
  # model nils the value. The hint sat outside that hidden block and told the
  # reader to set a date the screen does not offer.
  test "a reserve is not told to set a target date" do
    visit new_goal_path

    # The hint only appears once there is an amount and an account to pace, so
    # a one-off has to be brought to that state before the reserve can be shown
    # not to reach it.
    find("input[name='goal[target_amount]']").fill_in(with: "1000")
    find("input[name='goal[account_ids][]']", match: :first).click
    assert_text I18n.t("goals.form.suggested_no_date")

    choose I18n.t("goals.form.kinds.maintained.label")

    assert_not page.has_text?(I18n.t("goals.form.suggested_no_date")),
               "the reserve was told to set a date it cannot have"
  end

  # The categories decide what the months are counted from, so the picker
  # belongs with the months and nowhere else.
  test "the categories appear with the months and not before" do
    visit new_goal_path

    assert_not page.has_text?(I18n.t("goals.form.fields.expense_categories")),
               "the categories showed before the months they belong to"

    choose I18n.t("goals.form.kinds.maintained.label")
    select I18n.t("goals.form.target_modes.months_of_expenses"),
           from: I18n.t("goals.form.fields.target_mode")

    assert_text I18n.t("goals.form.fields.expense_categories")
  end
end
