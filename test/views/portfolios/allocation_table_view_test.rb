require "test_helper"

class PortfoliosAllocationTableViewTest < ActionView::TestCase
  include PortfoliosHelper

  setup do
    @statement = InvestmentStatement.new(users(:family_admin).family, user: users(:family_admin))
    @segment = InvestmentStatement.const_get(:AllocationSegment).new(id: "sec-1", name: "A share", amount: Money.new(1, "USD"), weight: 100)
  end

  test "the deepest level marks its rows as grandchildren" do
    render partial: "portfolios/allocation_table",
           locals: { statement: @statement, segments: [ @segment ], by: "security", parent: nil, depth: 2, parent_name: "Equity" }

    assert_select "[data-portfolio-grandchild='sec-1']", count: 1
  end

  # A level below the three the markup names has no marker; it raises rather
  # than render rows whose data attribute says nothing.
  test "a level deeper than the ladder raises" do
    error = assert_raises(ActionView::Template::Error) do
      render partial: "portfolios/allocation_table",
             locals: { statement: @statement, segments: [ @segment ], by: "security", parent: nil, depth: 3, parent_name: "Equity" }
    end

    assert_kind_of IndexError, error.cause
  end
end
