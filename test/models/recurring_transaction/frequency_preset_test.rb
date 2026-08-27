require "test_helper"

class RecurringTransaction::FrequencyPresetTest < ActiveSupport::TestCase
  Preset = RecurringTransaction::FrequencyPreset

  def setup
    @recurring = recurring_transactions(:netflix_subscription)
  end

  test "detect reads zero rules as legacy monthly on the expected day" do
    found = Preset.detect(@recurring)
    assert_equal "monthly", found.key
    assert_equal @recurring.expected_day_of_month, found.day_of_month
  end

  test "apply weekly replaces the rules and syncs the non-authoritative day" do
    @recurring.update!(anchor_date: Date.new(2026, 8, 7))
    Preset.apply(@recurring, preset: "weekly", weekday: "5")
    @recurring.save!

    rules = @recurring.recurrence_rules.reload
    assert_equal 1, rules.size
    assert_equal "weekly", rules.first.frequency
    assert_equal 5, rules.first.weekday
    assert_equal 7, @recurring.expected_day_of_month, "weekly bills carry the anchor's day, not the old monthly day"

    assert_equal "weekly", Preset.detect(@recurring.reload).key
  end

  test "apply biweekly ensures an anchor and an interval of 2" do
    @recurring.update!(anchor_date: nil)
    Preset.apply(@recurring, preset: "biweekly", weekday: "5")
    @recurring.save!

    rule = @recurring.recurrence_rules.reload.first
    assert_equal 2, rule.interval
    assert_equal @recurring.last_occurrence_date, @recurring.anchor_date
    assert_equal "biweekly", Preset.detect(@recurring).key
  end

  test "apply semimonthly builds two sorted monthly rules" do
    Preset.apply(@recurring, preset: "semimonthly", day_of_month: "20", second_day_of_month: "5")
    @recurring.save!

    days = @recurring.recurrence_rules.reload.map(&:day_of_month)
    assert_equal [ 5, 20 ], days
    assert_equal 5, @recurring.expected_day_of_month

    found = Preset.detect(@recurring)
    assert_equal "semimonthly", found.key
    assert_equal 5, found.day_of_month
    assert_equal 20, found.second_day_of_month
  end

  test "apply annual defaults month and day from the anchor" do
    @recurring.update!(anchor_date: Date.new(2026, 3, 14))
    Preset.apply(@recurring, preset: "annual")
    @recurring.save!

    rule = @recurring.recurrence_rules.reload.first
    assert_equal "yearly", rule.frequency
    assert_equal 3, rule.month_of_year
    assert_equal 14, rule.day_of_month
  end

  test "apply is a no-op when the submitted cadence matches the current one" do
    Preset.apply(@recurring, preset: "quarterly", day_of_month: "10")
    @recurring.save!
    rule_ids = @recurring.recurrence_rules.reload.map(&:id)

    Preset.apply(@recurring, preset: "quarterly", day_of_month: "10")
    @recurring.save!

    assert_equal rule_ids, @recurring.recurrence_rules.reload.map(&:id)
  end

  test "apply with last day sets expected_day_of_month to 31" do
    Preset.apply(@recurring, preset: "monthly", day_of_month: RecurrenceRule::LAST.to_s)
    @recurring.save!

    assert_equal RecurrenceRule::LAST, @recurring.recurrence_rules.reload.first.day_of_month
    assert_equal 31, @recurring.expected_day_of_month
  end

  test "apply ignores unknown presets and custom" do
    Preset.apply(@recurring, preset: "custom")
    Preset.apply(@recurring, preset: "hourly")
    assert_empty @recurring.recurrence_rules
  end

  test "shapes the picker cannot express detect as custom" do
    @recurring.recurrence_rules.create!(frequency: "monthly", weekday: 5, weekday_ordinal: 3)
    assert_equal "custom", Preset.detect(@recurring.reload).key
  end

  test "labels read naturally" do
    assert_equal "Monthly on the 5th", Preset.label(@recurring)

    Preset.apply(@recurring, preset: "biweekly", weekday: "5")
    @recurring.save!
    assert_equal "Every 2 weeks on Friday", Preset.label(@recurring.reload)

    Preset.apply(@recurring, preset: "monthly", day_of_month: RecurrenceRule::LAST.to_s)
    @recurring.save!
    assert_equal "Monthly on the last day", Preset.label(@recurring.reload)
  end

  test "monthly equivalent amount normalizes cadence" do
    assert_in_delta @recurring.amount, @recurring.monthly_equivalent_amount.amount.to_f, 0.01

    Preset.apply(@recurring, preset: "annual")
    @recurring.save!
    assert_in_delta @recurring.amount / 12.0, @recurring.reload.monthly_equivalent_amount.amount.to_f, 0.01
  end

  # (15, LAST) and (LAST, 15) are one schedule. Without a canonical order each
  # reapply rewrote the rules instead of no-opping, and two equal anchors made
  # two identical monthly rules read back as semimonthly.
  test "semimonthly with a last-day anchor round-trips as a no-op" do
    Preset.apply(@recurring, preset: "semimonthly",
                 day_of_month: 15, second_day_of_month: RecurrenceRule::LAST)
    @recurring.save!
    first_shape = @recurring.recurrence_rules.reload.map { |r| [ r.frequency, r.day_of_month ] }.sort_by(&:to_s)

    found = Preset.detect(@recurring)
    assert_equal "semimonthly", found.key

    Preset.apply(@recurring, preset: "semimonthly",
                 day_of_month: found.day_of_month, second_day_of_month: found.second_day_of_month)
    @recurring.save!

    assert_equal first_shape,
      @recurring.recurrence_rules.reload.map { |r| [ r.frequency, r.day_of_month ] }.sort_by(&:to_s),
      "reapplying what detect reported must change nothing"
  end

  test "two equal anchors are one monthly schedule" do
    Preset.apply(@recurring, preset: "semimonthly", day_of_month: 5, second_day_of_month: 5)
    @recurring.save!

    assert_equal "monthly", Preset.detect(@recurring.reload).key
  end
end
