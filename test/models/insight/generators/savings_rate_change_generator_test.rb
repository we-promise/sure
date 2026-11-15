require "test_helper"

class Insight::Generators::SavingsRateChangeGeneratorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
    # Far enough back that the fixture entries, dated in the real current
    # month, fall outside both compared months.
    @today = (Date.current - 4.months).change(day: 10)
    @last_month = @today.beginning_of_month - 1.month
    @prior_month = @last_month - 1.month
  end

  test "reports a change between two ordinary months" do
    travel_to @today do
      month(@prior_month, income: 5_000, spending: 4_000)
      month(@last_month, income: 5_000, spending: 3_000)

      insights = generate

      assert_equal 1, insights.size
      assert_equal "savings_rate_change.up", insights.first.template_key
      assert_equal({ current_rate: 40.0, previous_rate: 20.0 }, insights.first.metadata)
    end
  end

  test "reports a drop into spending more than was earned" do
    travel_to @today do
      month(@prior_month, income: 5_000, spending: 4_000)
      month(@last_month, income: 5_000, spending: 7_500)

      assert_equal [ "savings_rate_change.down_negative" ], generate.map(&:template_key)
    end
  end

  # A month that spent almost four times what came in (-279%) is one whose pay
  # landed in the month next to it. A 300-point "improvement" measured from it
  # says when the money arrived, not how the family saved.
  test "does not compare against a month whose income landed elsewhere" do
    travel_to @today do
      month(@prior_month, income: 1_000, spending: 3_788)
      month(@last_month, income: 5_000, spending: 3_000)

      assert_empty generate
    end
  end

  test "does not report a fall into a month whose income landed elsewhere" do
    travel_to @today do
      month(@prior_month, income: 5_000, spending: 3_000)
      month(@last_month, income: 1_000, spending: 3_788)

      assert_empty generate
    end
  end

  private
    def generate
      Insight::Generators::SavingsRateChangeGenerator.new(@family).generate
    end

    def month(start_date, income:, spending:)
      create_transaction(amount: -income, date: start_date.change(day: 2), name: "Pay #{start_date}")
      create_transaction(amount: spending, date: start_date.change(day: 5), name: "Spend #{start_date}")
    end
end
