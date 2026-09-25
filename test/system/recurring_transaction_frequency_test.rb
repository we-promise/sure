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

  # A hidden field still submits and is still constraint-validated: an
  # out-of-range count left behind a hidden group made the browser refuse to
  # submit, with no visible error and nothing to focus.
  test "a count left out of range behind a hidden group does not block Save" do
    visit edit_recurring_transaction_url(@recurring)

    select I18n.t("recurring_transactions.frequency_presets.interval"),
           from: I18n.t("recurring_transactions.form.frequency_label")
    fill_in I18n.t("recurring_transactions.form.frequency_interval_label"), with: "150"

    select I18n.t("recurring_transactions.frequency_presets.weekly"),
           from: I18n.t("recurring_transactions.form.frequency_label")
    select I18n.t("date.day_names")[5],
           from: I18n.t("recurring_transactions.form.frequency_weekday_label")
    click_button I18n.t("recurring_transactions.form.submit")

    visit bills_url(view: "all")
    assert_text I18n.t("recurring_transactions.frequency.weekly", weekday: I18n.t("date.day_names")[5])
    assert_equal [ [ "weekly", 1, 5 ] ],
                 @recurring.reload.recurrence_rules.map { |rule| [ rule.frequency, rule.interval, rule.weekday ] }
  end

  test "a custom interval asks for the day that fits its unit and saves" do
    visit edit_recurring_transaction_url(@recurring)

    interval_group = find("[data-presets='interval']", visible: :all)
    weekday_field = find("[data-presets='weekly,biweekly']", visible: :all)
    assert_not interval_group.visible?

    select I18n.t("recurring_transactions.frequency_presets.interval"),
           from: I18n.t("recurring_transactions.form.frequency_label")
    assert interval_group.visible?

    # Months is the default unit, so the day-of-month group shows first.
    assert_not weekday_field.visible?
    select I18n.t("recurring_transactions.frequency_interval_units.weekly"),
           from: I18n.t("recurring_transactions.form.frequency_interval_unit_label")
    assert weekday_field.visible?

    fill_in I18n.t("recurring_transactions.form.frequency_interval_label"), with: "3"
    select I18n.t("date.day_names")[5],
           from: I18n.t("recurring_transactions.form.frequency_weekday_label")
    click_button I18n.t("recurring_transactions.form.submit")

    visit bills_url(view: "all")
    assert_text I18n.t("recurring_transactions.frequency.every_n_weeks", interval: 3, weekday: I18n.t("date.day_names")[5])
    assert_equal [ [ "weekly", 3, 5 ] ],
                 @recurring.reload.recurrence_rules.map { |rule| [ rule.frequency, rule.interval, rule.weekday ] }
  end
end
