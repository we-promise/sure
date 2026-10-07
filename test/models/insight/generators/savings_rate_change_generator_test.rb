require "test_helper"

class Insight::Generators::SavingsRateChangeGeneratorTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:dylan_family)
  end

  # Far enough back that the relative-date fixture entries fall after it.
  def today
    @today ||= (Date.current - 6.months).change(day: 15)
  end

  # Both months save half of a 1,000 income on the shared `depository`. The
  # extra spend sits on `connected`, private to family_admin, so the shared
  # feed must not read it as a drop in the family's savings rate.
  test "ignores spending on an account private to one member" do
    travel_to today do
      last_month = Period.last_month_for(@family).start_date
      prior_month = last_month - 1.month

      [ prior_month, last_month ].each do |month|
        create_transaction(amount: -1_000, date: month.change(day: 2), name: "salary #{month}")
        create_transaction(amount: 500, date: month.change(day: 5), name: "rent #{month}")
      end
      create_transaction(amount: 400, date: last_month.change(day: 9), name: "private",
                         account: accounts(:connected))

      assert_empty Insight::Generators::SavingsRateChangeGenerator.new(@family).generate
    end
  end
end
