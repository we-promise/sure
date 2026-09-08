require "test_helper"

class RecurrenceRuleTest < ActiveSupport::TestCase
  def setup
    @recurring = recurring_transactions(:netflix_subscription)
  end

  test "monthly rule with a day of month is valid" do
    rule = @recurring.recurrence_rules.build(frequency: "monthly", day_of_month: 15)
    assert rule.valid?, rule.errors.full_messages.join(", ")
  end

  test "monthly rule accepts -1 as last day of month" do
    rule = @recurring.recurrence_rules.build(frequency: "monthly", day_of_month: -1)
    assert rule.valid?
  end

  test "monthly rule with an nth weekday is valid" do
    rule = @recurring.recurrence_rules.build(frequency: "monthly", weekday: 5, weekday_ordinal: 3)
    assert rule.valid?
  end

  test "monthly rule requires exactly one day spec" do
    neither = @recurring.recurrence_rules.build(frequency: "monthly")
    assert_not neither.valid?

    both = @recurring.recurrence_rules.build(frequency: "monthly", day_of_month: 15, weekday: 5, weekday_ordinal: 3)
    assert_not both.valid?
  end

  test "monthly weekday rule requires the ordinal" do
    rule = @recurring.recurrence_rules.build(frequency: "monthly", weekday: 5)
    assert_not rule.valid?
    assert rule.errors[:weekday_ordinal].any?
  end

  test "weekly rule requires a weekday and rejects month-shaped fields" do
    valid = @recurring.recurrence_rules.build(frequency: "weekly", weekday: 4)
    assert valid.valid?

    no_weekday = @recurring.recurrence_rules.build(frequency: "weekly")
    assert_not no_weekday.valid?

    with_day = @recurring.recurrence_rules.build(frequency: "weekly", weekday: 4, day_of_month: 10)
    assert_not with_day.valid?

    with_ordinal = @recurring.recurrence_rules.build(frequency: "weekly", weekday: 4, weekday_ordinal: 2)
    assert_not with_ordinal.valid?
  end

  test "yearly rule requires a month and a day spec" do
    valid = @recurring.recurrence_rules.build(frequency: "yearly", month_of_year: 11, day_of_month: 1)
    assert valid.valid?

    thanksgiving = @recurring.recurrence_rules.build(frequency: "yearly", month_of_year: 11, weekday: 4, weekday_ordinal: 4)
    assert thanksgiving.valid?

    no_month = @recurring.recurrence_rules.build(frequency: "yearly", day_of_month: 1)
    assert_not no_month.valid?
  end

  test "monthly rule rejects month_of_year" do
    rule = @recurring.recurrence_rules.build(frequency: "monthly", day_of_month: 5, month_of_year: 3)
    assert_not rule.valid?
  end

  test "interval must be positive" do
    rule = @recurring.recurrence_rules.build(frequency: "monthly", day_of_month: 5, interval: 0)
    assert_not rule.valid?
  end

  test "position collisions are caught by the database index" do
    # No model-level uniqueness validation on purpose: rules are rewritten as
    # a set (old rows marked for destruction alongside new builds), and a
    # validation would see the doomed rows and reject the rewrite.
    @recurring.recurrence_rules.create!(frequency: "monthly", day_of_month: 1, position: 0)

    assert_raises ActiveRecord::RecordNotUnique do
      @recurring.recurrence_rules.create!(frequency: "monthly", day_of_month: 15, position: 0)
    end
  end

  test "series with an interval rule requires an anchor date" do
    @recurring.recurrence_rules.create!(frequency: "weekly", weekday: 5, interval: 2)
    @recurring.anchor_date = nil
    assert_not @recurring.valid?
    assert @recurring.errors[:anchor_date].any?

    @recurring.anchor_date = Date.new(2026, 8, 7)
    assert @recurring.valid?
  end

  test "series end mode fields are validated together" do
    @recurring.end_mode = "on_date"
    assert_not @recurring.valid?

    @recurring.end_on = Date.new(2027, 1, 1)
    assert @recurring.valid?

    @recurring.end_mode = "after_count"
    @recurring.end_on = nil
    assert_not @recurring.valid?

    @recurring.end_after_count = 12
    assert @recurring.valid?
  end

  test "rules are destroyed with their series" do
    @recurring.recurrence_rules.create!(frequency: "monthly", day_of_month: 5)
    assert_difference "RecurrenceRule.count", -1 do
      @recurring.destroy!
    end
  end

  test "a week-of-month anchor without a weekday is rejected" do
    rule = @recurring.recurrence_rules.build(frequency: "monthly", day_of_month: 10, weekday_ordinal: 2)

    assert_not rule.valid?
    assert rule.errors[:weekday_ordinal].any?,
      "an ordinal with no weekday persists an incoherent day anchor"
  end
end
