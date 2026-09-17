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

  test "day options end with the last-day sentinel" do
    label, value = frequency_day_options.last

    assert_equal RecurrenceRule::LAST, value
    assert_equal I18n.t("recurring_transactions.frequency.last_day"), label
  end
end
