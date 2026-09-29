require "test_helper"

class RecurringTransactionsHelperTest < ActionView::TestCase
  include ApplicationHelper

  # ordinalize always emits English suffixes; the day picker has to follow the
  # active locale the way ApplicationHelper#localized_ordinal does.
  test "day options follow the locale's ordinals" do
    assert_equal "1st", frequency_day_options.first.first

    I18n.with_locale(:ca) do
      assert_equal "1r", frequency_day_options.first.first
    end
  end

  test "the two custom options follow the named presets, together" do
    series = recurring_transactions(:netflix_subscription)
    assert_equal "interval", frequency_preset_options(series).last.last

    series.recurrence_rules.create!(frequency: "monthly", weekday: 5, weekday_ordinal: 3)
    values = frequency_preset_options(series.reload).map(&:last)

    assert_equal RecurringTransaction::FrequencyPreset::PRESETS, values.first(RecurringTransaction::FrequencyPreset::PRESETS.size)
    assert_equal %w[custom interval], values.last(2)
  end

  test "day options end with the last-day sentinel" do
    label, value = frequency_day_options.last

    assert_equal RecurrenceRule::LAST, value
    assert_equal I18n.t("recurring_transactions.frequency.last_day"), label
  end
end
