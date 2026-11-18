require "test_helper"

class Insight::Generators::SavingsRateChangeGeneratorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    # Far enough back that the fixture entries, dated in the real current
    # month, fall outside both compared windows.
    @today = (Date.current - 7.months).change(day: 10)
    last_month = @today.beginning_of_month - 1.month
    # Oldest first: the previous window's three months, then the last three.
    @months = (0..5).map { |i| last_month - (5 - i).months }
  end

  test "compares the last three complete months with the three before" do
    travel_to @today do
      @months.first(3).each { |month| record(month, income: 5_000, spending: 4_000) }
      @months.last(3).each { |month| record(month, income: 5_000, spending: 3_000) }

      insight = generate.sole

      assert_equal "savings_rate_change.up", insight.template_key
      assert_equal({ current_rate: 40.0, previous_rate: 20.0 }, insight.metadata.except(:accounts_digest))
      assert_equal @months[3], insight.period_start
      assert_equal @months[5].end_of_month, insight.period_end
      assert_equal I18n.l(@months[3], format: "%B"), insight.facts[:from_month]
      assert_equal I18n.l(@months[5], format: "%B"), insight.facts[:to_month]
      assert_equal "savings_rate_change:v2:#{@months[5].strftime("%Y-%m")}", insight.dedup_key
    end
  end

  test "reports a drop into spending more than was earned" do
    travel_to @today do
      @months.first(3).each { |month| record(month, income: 5_000, spending: 4_000) }
      @months.last(3).each { |month| record(month, income: 5_000, spending: 5_500) }

      assert_equal [ "savings_rate_change.down_negative" ], generate.map(&:template_key)
    end
  end

  # A 5,000 salary paid on the 29th instead of the 1st gives one month two
  # salaries and the next none. Month against month that reads as a jump from
  # -33% to 50%; inside one window it changes nothing.
  test "does not report a paycheck that moved between months of the same window" do
    travel_to @today do
      @months.first(3).each { |month| record(month, income: 8_000, spending: 4_000) }
      record(@months[3], income: 13_000, spending: 4_000)
      record(@months[4], income: 3_000, spending: 4_000)
      record(@months[5], income: 8_000, spending: 4_000)

      assert_empty generate
    end
  end

  # Averaging the monthly rates would let one month whose pay landed
  # elsewhere (-279%) drag the earlier window down to about -68%, and report
  # a recovery of 88 points that never happened.
  test "does not average monthly rates" do
    travel_to @today do
      record(@months[0], income: 1_000, spending: 3_788)
      record(@months[1], income: 9_000, spending: 4_000)
      record(@months[2], income: 5_000, spending: 4_000)
      @months.last(3).each { |month| record(month, income: 5_000, spending: 4_000) }

      assert_empty generate
    end
  end

  # A 5,000 salary normally paid on the 1st arrives once on the last day of the
  # month before. Run by run, that month enters the latest window (two
  # salaries in one month), then sits on the edge between the windows three
  # months later, then leaves through the earlier window three months after
  # that. None of those runs is a change in how the family saves.
  test "does not report a paycheck paid early, in any window position" do
    early = @months[3]
    months = (-6..5).map { |offset| early + offset.months }

    months.each do |month|
      salaries = if month == early - 1.month then 2 elsif month == early then 0 else 1 end
      record(month, income: 5_000 * salaries, spending: 4_000)
    end

    (0..6).each do |runs_later|
      travel_to((early + runs_later.months).change(day: 10)) do
        assert_empty generate, "#{runs_later} months after the early payday"
      end
    end
  end

  test "reports a raise once the latest window earns it" do
    travel_to @today do
      @months.first(3).each { |month| record(month, income: 5_000, spending: 4_000) }
      @months.last(3).each { |month| record(month, income: 6_000, spending: 4_000) }

      assert_equal [ "savings_rate_change.up" ], generate.map(&:template_key)
    end
  end

  test "reports a drop in income" do
    travel_to @today do
      @months.first(3).each { |month| record(month, income: 5_000, spending: 4_000) }
      @months.last(3).each { |month| record(month, income: 4_500, spending: 4_000) }

      assert_equal [ "savings_rate_change.down" ], generate.map(&:template_key)
    end
  end

  # Spending is summed, not smoothed: a one-off 1,500 in a single month moves
  # the window's rate from 20% to 10%.
  test "reports a one-off rise in spending" do
    travel_to @today do
      @months.first(3).each { |month| record(month, income: 5_000, spending: 4_000) }
      record(@months[3], income: 5_000, spending: 5_500)
      @months.last(2).each { |month| record(month, income: 5_000, spending: 4_000) }

      assert_equal({ current_rate: 10.0, previous_rate: 20.0 }, generate.sole.metadata.except(:accounts_digest))
    end
  end

  # A bonus month lifts the window's real income above its spending while
  # the median-based rate is negative. "You spent more than you earned" would
  # be false; the plain "down" copy still reports the drop.
  test "says spending passed income only when the window's totals say so" do
    travel_to @today do
      @months.first(3).each { |month| record(month, income: 5_000, spending: 4_000) }
      record(@months[3], income: 2_000, spending: 4_000)
      record(@months[4], income: 2_000, spending: 4_000)
      record(@months[5], income: 12_000, spending: 4_000)

      assert_equal [ "savings_rate_change.down" ], generate.map(&:template_key)
    end
  end

  # The same window saved 25% of what came in, while the rate reads -100%:
  # the copy has to say the rate is measured against typical monthly income,
  # not that the family saved -100% of its income.
  test "names the typical-income basis of the rate it reports" do
    travel_to @today do
      @months.first(3).each { |month| record(month, income: 5_000, spending: 4_000) }
      record(@months[3], income: 2_000, spending: 4_000)
      record(@months[4], income: 2_000, spending: 4_000)
      record(@months[5], income: 12_000, spending: 4_000)

      body = Insight::BodyWriter.new.write(generate.sole)

      assert_includes body, "against your typical monthly income was −100.0%"
      assert_no_match(/of your income/, body)
    end
  end

  # With months starting on the 15th the window runs from the 15th to the
  # 14th, which month names alone would misreport.
  test "names a custom-month window by its dates" do
    @family.update!(month_start_day: 15)
    today = (Date.current - 7.months).change(day: 20)
    window_start = (today.change(day: 15) - 3.months)
    starts = (0..5).map { |i| window_start - 3.months + i.months }

    travel_to today do
      starts.first(3).each { |start| record(start, income: 5_000, spending: 4_000) }
      starts.last(3).each { |start| record(start, income: 5_000, spending: 3_000) }

      facts = generate.sole.facts

      assert_equal I18n.l(window_start, format: :short), facts[:from_month]
      assert_equal I18n.l(today.change(day: 14), format: :short), facts[:to_month]
    end
  end

  test "does not report without income in both windows" do
    travel_to @today do
      @months.last(3).each { |month| record(month, income: 5_000, spending: 3_000) }

      assert_empty generate
    end
  end

  # The generator passes no interpolation to the title, so a translation still
  # asking for one would show the raw placeholder to the users of that locale.
  test "titles need no interpolation in any locale" do
    I18n.available_locales.product(%w[up down]).each do |locale, direction|
      assert_no_match(/%\{/, I18n.t!("insights.titles.savings_rate_change.#{direction}", locale: locale), locale)
    end
  end

  # Both windows save half of a 1,000 monthly income on the shared
  # `depository`. The extra spend sits on `connected`, private to
  # family_admin, so the shared feed must not read it as a drop in the
  # family's savings rate.
  test "ignores spending on an account private to one member" do
    travel_to @today do
      @months.each { |month| record(month, income: 1_000, spending: 500) }
      create_transaction(amount: 1_200, date: @months[5] + 8.days, name: "Private spend",
                         account: accounts(:connected))

      assert_empty generate
    end
  end

  # Moving money into a term deposit or brokerage account is saved money. A
  # window that saves 1,000 a month more than the one before must not read as
  # a drop in the savings rate just because the budget books the transfer as
  # spending.
  test "money moved into savings accounts does not lower the savings rate" do
    travel_to @today do
      @months.first(3).each { |month| record(month, income: 4_000, spending: 1_000) }
      @months.last(3).each { |month| record(month, income: 4_000, spending: 1_000, saved: 1_000) }

      assert_empty generate
    end
  end

  test "reports a real change in the savings rate next to money saved" do
    travel_to @today do
      @months.first(3).each { |month| record(month, income: 4_000, spending: 1_000) }
      @months.last(3).each { |month| record(month, income: 4_000, spending: 2_000, saved: 1_000) }

      insight = generate.sole

      assert_equal 50.0, insight.metadata[:current_rate]
      assert_equal 75.0, insight.metadata[:previous_rate]
    end
  end

  private
    def generate
      Insight::Generators::SavingsRateChangeGenerator.new(@family).generate
    end

    # Pay on the month's first day, spending four days later.
    def record(month, income:, spending:, saved: 0)
      create_transaction(amount: -income, date: month + 1.day, name: "Pay #{month}") if income.positive?
      create_transaction(amount: spending, date: month + 4.days, name: "Spend #{month}")
      return if saved.zero?

      create_transaction(amount: saved, date: month + 5.days, name: "Save #{month}", kind: "investment_contribution")
    end
end
