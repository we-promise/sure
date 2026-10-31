require "test_helper"

class Insight::Generators::SavingsRateChangeGeneratorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
  end

  # Anchor two months back so the relative-date fixture entries (always in the
  # real current month) can't leak into the compared months.
  def anchor
    @anchor ||= (Date.current - 2.months).change(day: 10)
  end

  def month(offset)
    (anchor.beginning_of_month - offset.months).beginning_of_month
  end

  def book_month(start, income:, spending:, saved: 0)
    create_transaction(amount: -income, date: start.change(day: 2), name: "Salary #{start}")
    create_transaction(amount: spending, date: start.change(day: 5), name: "Spending #{start}")
    return if saved.zero?

    create_transaction(amount: saved, date: start.change(day: 6), name: "Saving #{start}", kind: "investment_contribution")
  end

  def generate
    Insight::Generators::SavingsRateChangeGenerator.new(@family).generate
  end

  # Moving money into a term deposit or brokerage account is saved money. A
  # month that saves 1,000 more than the month before must not read as a drop
  # in the savings rate just because the budget books the transfer as spending.
  test "money moved into savings accounts does not lower the savings rate" do
    travel_to anchor do
      book_month(month(2), income: 4_000, spending: 1_000)
      book_month(month(1), income: 4_000, spending: 1_000, saved: 1_000)

      assert_empty generate
    end
  end

  test "reports a real change in the savings rate" do
    travel_to anchor do
      book_month(month(2), income: 4_000, spending: 1_000)
      book_month(month(1), income: 4_000, spending: 2_000, saved: 1_000)

      insights = generate

      assert_equal 1, insights.size
      assert_equal 50.0, insights.first.metadata[:current_rate]
      assert_equal 75.0, insights.first.metadata[:previous_rate]
    end
  end
end
