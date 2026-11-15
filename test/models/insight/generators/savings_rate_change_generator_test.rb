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
      assert_equal({ current_rate: 40.0, previous_rate: 20.0 }, insight.metadata)
      assert_equal @months[3], insight.period_start
      assert_equal @months[5].end_of_month, insight.period_end
      assert_equal I18n.l(@months[3], format: "%B"), insight.facts[:from_month]
      assert_equal I18n.l(@months[5], format: "%B"), insight.facts[:to_month]
      assert_equal "savings_rate_change:#{@months[5].strftime("%Y-%m")}", insight.dedup_key
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

  # Each window's rate comes from its summed income and spending. Averaging
  # the monthly rates instead would let one month whose pay landed elsewhere
  # (-279%) drag the earlier window down to about -68%, and report a
  # recovery of 88 points that never happened.
  test "computes each window's rate from its totals, not from monthly rates" do
    travel_to @today do
      record(@months[0], income: 1_000, spending: 3_788)
      record(@months[1], income: 9_000, spending: 4_000)
      record(@months[2], income: 5_000, spending: 4_000)
      @months.last(3).each { |month| record(month, income: 5_000, spending: 4_000) }

      assert_empty generate
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

  private
    def generate
      Insight::Generators::SavingsRateChangeGenerator.new(@family).generate
    end

    def record(month, income:, spending:)
      create_transaction(amount: -income, date: month.change(day: 2), name: "Pay #{month}") if income.positive?
      create_transaction(amount: spending, date: month.change(day: 5), name: "Spend #{month}")
    end
end
