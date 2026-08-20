require "application_system_test_case"

class RecurringTransactionFrequencyTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @recurring = recurring_transactions(:netflix_subscription)
  end

  test "the frequency picker reveals the fields for the chosen preset and saves" do
    visit edit_recurring_transaction_url(@recurring)

    # Monthly is the current cadence: the day group shows, the weekday group
    # does not.
    day_field = find("[data-presets*='monthly']", match: :first, visible: :all)
    weekday_field = find("[data-presets='weekly,biweekly']", visible: :all)
    assert day_field.visible?
    assert_not weekday_field.visible?

    select I18n.t("recurring_transactions.frequency_presets.biweekly"),
           from: I18n.t("recurring_transactions.form.frequency_label")

    assert weekday_field.visible?
    assert_not day_field.visible?

    select I18n.t("date.day_names")[5],
           from: I18n.t("recurring_transactions.form.frequency_weekday_label")
    click_button I18n.t("recurring_transactions.form.submit")

    # The update redirects via the referer; the cadence label lives on the
    # All bills management view now.
    visit bills_url(view: "all")
    assert_text I18n.t("recurring_transactions.frequency.biweekly", weekday: I18n.t("date.day_names")[5])
    assert_equal [ [ "weekly", 2, 5 ] ],
                 @recurring.reload.recurrence_rules.map { |rule| [ rule.frequency, rule.interval, rule.weekday ] }
  end
end
