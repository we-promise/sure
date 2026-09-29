require "test_helper"

class Insight::Generators::SpendingAnomalyGeneratorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    @category = @family.categories.create!(name: "Pace Test Cat", color: "#101010", lucide_icon: "circle")
  end

  # Anchor two months back so the relative-date fixture entries (always in the
  # real current month) can't leak into the baseline or current periods. Day 10
  # gives 10 elapsed days, comfortably past MIN_ELAPSED_DAYS.
  def anchor
    @anchor ||= (Date.current - 2.months).change(day: 10)
  end

  def month_start(offset)
    (anchor.beginning_of_month - offset.months).beginning_of_month
  end

  def spend(month, total)
    create_transaction(category: @category, amount: total, date: month.change(day: 3), name: "test #{month}")
  end

  def generate
    Insight::Generators::SpendingAnomalyGenerator.new(@family).generate
  end

  # $1,000 spent by day 10 against a $3,000 monthly baseline is exactly on pace:
  # projected over a 28-31 day month it lands within 7% of the baseline, well
  # inside DEVIATION_THRESHOLD_PCT. Without the pace factor the raw $1,000 reads
  # as 67% below baseline and produces a high-priority false alarm.
  test "does not flag a category that is on pace for its baseline" do
    travel_to anchor do
      3.times { |i| spend(month_start(i + 1), 3_000) }
      spend(anchor.beginning_of_month, 1_000)

      assert_empty generate
    end
  end

  # The same $1,000 by day 10, but against a $1,000 monthly baseline, projects to
  # roughly triple the usual month and must be flagged. Without the pace factor
  # the raw total matches the baseline exactly and nothing is reported.
  test "flags a category running well ahead of its baseline" do
    travel_to anchor do
      3.times { |i| spend(month_start(i + 1), 1_000) }
      spend(anchor.beginning_of_month, 1_000)

      insights = generate

      assert_equal 1, insights.size
      assert_equal "above", insights.first.metadata[:direction]
      assert_equal "high", insights.first.priority
    end
  end
end
