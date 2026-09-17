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
end
