require "test_helper"

class Budget::SearchTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @march = @family.budgets.create!(start_date: Date.new(2024, 3, 1), end_date: Date.new(2024, 3, 31), currency: "USD")
    @april = @family.budgets.create!(start_date: Date.new(2024, 4, 1), end_date: Date.new(2024, 4, 30), currency: "USD")
    @scope = @family.budgets.where(id: [ @march.id, @april.id ])
  end

  test "with no filters returns the scope it is given" do
    assert_equal [ @april, @march ].sort_by(&:id), Budget::Search.new(@scope).budgets_scope.sort_by(&:id)
  end

  test "start_date keeps budgets starting on or after it" do
    assert_equal [ @april ], search(start_date: @april.start_date).to_a
    assert_equal [ @april ], search(start_date: @march.start_date + 1.day).to_a
  end

  test "end_date keeps budgets ending on or before it" do
    assert_equal [ @march ], search(end_date: @march.end_date).to_a
    assert_equal [ @march ], search(end_date: @april.end_date - 1.day).to_a
  end

  test "start_date and end_date together keep budgets inside the range" do
    assert_equal [ @march ], search(start_date: @march.start_date, end_date: @march.end_date).to_a
    assert_empty search(start_date: @april.start_date, end_date: @march.end_date)
  end

  test "never widens the scope it is given" do
    assert_equal [ @march ], Budget::Search.new(@scope.where(id: @march.id), filters: { start_date: Date.new(2000, 1, 1) }).budgets_scope.to_a
  end

  private
    def search(**filters)
      Budget::Search.new(@scope, filters:).budgets_scope
    end
end
