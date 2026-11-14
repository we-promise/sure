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

  test "apply interval writes one weekly rule every N weeks and reads it back" do
    @recurring.update!(anchor_date: nil)
    assert Preset.apply(@recurring, preset: "interval", interval: "3", interval_unit: "weekly", weekday: "5")
    @recurring.save!

    rule = @recurring.recurrence_rules.reload.sole
    assert_equal [ "weekly", 3, 5 ], [ rule.frequency, rule.interval, rule.weekday ]
    assert_equal @recurring.last_occurrence_date, @recurring.anchor_date, "an every-N cadence needs a phase"

    found = Preset.detect(@recurring)
    assert_equal [ "interval", 3, "weekly", 5 ], [ found.key, found.interval, found.interval_unit, found.weekday ]
    assert_equal "Every 3 weeks on Friday", Preset.label(@recurring)

    occurrences = @recurring.schedule.occurrences_between(@recurring.anchor_date, @recurring.anchor_date + 70)
    assert occurrences.all?(&:friday?)
    assert_equal [ 21 ], occurrences.each_cons(2).map { |a, b| (b - a).to_i }.uniq
  end

  test "apply interval in months and years anchors on the chosen day" do
    Preset.apply(@recurring, preset: "interval", interval: 2, interval_unit: "monthly", day_of_month: 12)
    @recurring.save!

    rule = @recurring.recurrence_rules.reload.sole
    assert_equal [ "monthly", 2, 12 ], [ rule.frequency, rule.interval, rule.day_of_month ]
    assert_equal 12, @recurring.expected_day_of_month
    assert_equal "Every 2 months on the 12th", Preset.label(@recurring)

    Preset.apply(@recurring, preset: "interval", interval: 2, interval_unit: "yearly",
                 day_of_month: 1, month_of_year: 9)
    @recurring.save!

    rule = @recurring.recurrence_rules.reload.sole
    assert_equal [ "yearly", 2, 1, 9 ], [ rule.frequency, rule.interval, rule.day_of_month, rule.month_of_year ]
    assert_equal "Every 2 years on September 1st", Preset.label(@recurring)
  end

  test "an interval a named preset covers is that preset" do
    Preset.apply(@recurring, preset: "interval", interval: 3, interval_unit: "monthly", day_of_month: 10)
    @recurring.save!
    rule_ids = @recurring.recurrence_rules.reload.map(&:id)

    assert_equal "quarterly", Preset.detect(@recurring).key
    assert_not Preset.apply(@recurring, preset: "quarterly", day_of_month: "10"),
               "quarterly entered either way is one schedule"
    assert_equal rule_ids, @recurring.recurrence_rules.reload.map(&:id)
  end

  test "reapplying a detected interval is a no-op" do
    Preset.apply(@recurring, preset: "interval", interval: 5, interval_unit: "weekly", weekday: 2)
    @recurring.save!
    found = Preset.detect(@recurring.reload)

    assert_not Preset.apply(@recurring, preset: "interval", interval: found.interval.to_s,
                            interval_unit: found.interval_unit, weekday: found.weekday.to_s)
  end

  test "apply interval reads the count as a whole base-10 number" do
    Preset.apply(@recurring, preset: "interval", interval: "08", interval_unit: "weekly", weekday: "5")
    @recurring.save!

    assert_equal 8, @recurring.recurrence_rules.reload.sole.interval, "a leading zero is not octal"
  end

  test "once is a single occurrence on the chosen date and not a monthly rate" do
    due = Date.new(2026, 12, 1)

    assert Preset.apply(@recurring, preset: "once", once_on: due)
    @recurring.save!

    rule = @recurring.recurrence_rules.reload.sole
    assert_equal [ "yearly", 1, 1, 12 ], [ rule.frequency, rule.interval, rule.day_of_month, rule.month_of_year ]
    assert @recurring.ends_after_count?
    assert_equal 1, @recurring.end_after_count
    assert_equal due, @recurring.anchor_date
    assert_equal due, @recurring.next_expected_date
    assert @recurring.one_off?
    assert_equal 0, @recurring.monthly_equivalent_amount.amount

    found = Preset.detect(@recurring)
    assert_equal [ "once", due ], [ found.key, found.once_on ]
    assert_equal I18n.t("recurring_transactions.frequency.once_on", date: I18n.l(due, format: :long)),
                 Preset.label(@recurring)

    assert_equal [ due ], @recurring.schedule.occurrences_between(due, due + 400)
    assert_not Preset.apply(@recurring, preset: "once", once_on: due.iso8601),
               "reapplying the same date must change nothing"
  end

  test "once rejects a date that was typed but cannot be parsed" do
    assert_not Preset.apply(@recurring, preset: "once", once_on: "2026-13-40")
    assert_includes @recurring.errors.full_messages,
                    I18n.t("recurring_transactions.create.due_date_required")
    assert_empty @recurring.recurrence_rules
  end

  test "moving a paid one-off is refused and leaves the schedule untouched" do
    due = Date.new(2026, 12, 1)
    Preset.apply(@recurring, preset: "once", once_on: due)
    @recurring.save!
    RecurringTransaction::Allocator.new(@recurring.recurring_occurrences.find_by!(due_on: due)).mark_paid!

    assert_not Preset.apply(@recurring, preset: "once", once_on: due + 10)
    assert_includes @recurring.errors.full_messages,
                    I18n.t("recurring_transactions.update.once_date_locked")
    assert_equal due, @recurring.reload.anchor_date
    assert_equal "once", Preset.detect(@recurring).key
  end

  test "changing a paid one-off to an installment does not unlock its date" do
    due = Date.new(2026, 12, 1)
    Preset.apply(@recurring, preset: "once", once_on: due)
    @recurring.save!
    RecurringTransaction::Allocator.new(@recurring.recurring_occurrences.find_by!(due_on: due)).mark_paid!

    @recurring.bill_type = "installment"

    assert_not Preset.apply(@recurring, preset: "once", once_on: due + 10)
    assert_includes @recurring.errors.full_messages,
                    I18n.t("recurring_transactions.update.once_date_locked")
    assert_equal due, @recurring.reload.anchor_date
  end

  test "an earlier paid occurrence does not lock a one-off's date" do
    travel_to Date.new(2026, 11, 13) do
      RecurringTransaction::OccurrenceGenerator.new(@recurring).generate!
      earlier = @recurring.recurring_occurrences.reload.find_by!(due_on: Date.new(2026, 11, 5))
      RecurringTransaction::Allocator.new(earlier).mark_paid!

      Preset.apply(@recurring, preset: "once", once_on: Date.new(2026, 12, 1))
      @recurring.save!

      assert Preset.apply(@recurring, preset: "once", once_on: Date.new(2026, 12, 20))
      assert_empty @recurring.errors
    end
  end

  test "once without a date is due on the bill's current due date, not its first" do
    stale = Date.new(2026, 1, 5)
    @recurring.update_columns(anchor_date: stale)
    due = @recurring.next_due_date

    assert Preset.apply(@recurring, preset: "once")

    assert_equal due, @recurring.anchor_date
    assert_equal due, @recurring.next_expected_date
  end

  test "leaving once drops the one-payment cap" do
    due = Date.new(2026, 12, 1)
    Preset.apply(@recurring, preset: "once", once_on: due)
    @recurring.save!

    assert Preset.apply(@recurring, preset: "monthly", day_of_month: due.day.to_s)
    @recurring.save!
    @recurring.reload

    assert @recurring.ends_never?
    assert_nil @recurring.end_after_count
    assert_equal "monthly", Preset.detect(@recurring).key
    assert_operator @recurring.schedule.occurrences_between(due, due + 70).size, :>, 1
  end

  test "a one-payment installment stays an installment, not a one-off" do
    @recurring.update!(bill_type: "installment", end_mode: "after_count", end_after_count: 1,
                       anchor_date: Date.new(2026, 12, 1))
    @recurring.recurrence_rules.create!(frequency: "yearly", day_of_month: 1, month_of_year: 12)

    assert_equal "annual", Preset.detect(@recurring.reload).key
    assert_not @recurring.one_off?
  end

  test "apply interval rejects an out-of-range, fractional or malformed count or an unknown unit" do
    [ [ "0", "weekly" ], [ "", "monthly" ], [ (Preset::MAX_INTERVAL + 1).to_s, "monthly" ], [ "2", "daily" ],
      [ "2.5", "monthly" ], [ "3abc", "weekly" ] ].each do |interval, unit|
      recurring = RecurringTransaction.find(@recurring.id)

      assert_not Preset.apply(recurring, preset: "interval", interval: interval, interval_unit: unit)
      assert recurring.errors.added?(:frequency_interval, :invalid), "#{interval} #{unit} must be refused"
      assert_empty recurring.recurrence_rules
    end
  end
end
