require "test_helper"

class IncomeStatement::ExpenseCategoryFilterTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @family = families(:empty)
    @checking = @family.accounts.create! name: "Checking", currency: @family.currency, balance: 5000, accountable: Depository.new
    @period = Period.custom(start_date: Date.new(2026, 6, 1), end_date: Date.new(2026, 6, 30))

    @food = @family.categories.create! name: "Food"
    @groceries = @family.categories.create! name: "Groceries", parent: @food
    @dining = @family.categories.create! name: "Dining", parent: @food
    @rent = @family.categories.create! name: "Rent"
    @unused = @family.categories.create! name: "Unused"

    create_transaction(account: @checking, amount: 40, date: Date.new(2026, 6, 10), category: @groceries)
    create_transaction(account: @checking, amount: 900, date: Date.new(2026, 6, 1), category: @rent)
    create_transaction(account: @checking, amount: 5, date: Date.new(2026, 6, 2))
  end

  test "offers every group with spending whole, Uncategorized first, all checked when nothing is picked" do
    filter = build_filter(nil)

    assert_equal [ Category::UNCATEGORIZED_FILTER_VALUE, @food.id, @dining.id, @groceries.id, @rent.id ], filter.options.map(&:value)
    assert filter.options.all?(&:checked)
    assert filter.options.all?(&:live)
    assert_nil filter.category_ids
  end

  test "a selection covering every option resolves to unfiltered" do
    filter = build_filter([ Category::UNCATEGORIZED_FILTER_VALUE, @food.id, @rent.id ])

    assert filter.options.all?(&:checked)
    assert_nil filter.category_ids
  end

  test "a subcategory alone leaves its parent and siblings unchecked" do
    filter = build_filter([ @groceries.id ])

    checked = filter.options.select(&:checked).map(&:value)
    assert_equal [ @groceries.id ], checked
    assert_equal [ @groceries.id ], filter.category_ids
  end

  test "a picked category with no spending is listed, not live, and keeps the filter" do
    filter = build_filter([ @unused.id ])

    unused = filter.options.find { |option| option.value == @unused.id }
    assert unused.checked
    assert_not unused.live
    assert_equal [ @unused.id ], filter.category_ids
  end

  test "selected count counts a parent as its subcategories, so narrowing a group lowers it" do
    # Food (both subcategories) + Rent
    assert_equal 3, build_filter([ @food.id, @groceries.id, @dining.id, @rent.id ]).selected_count
    # ...one subcategory unchecked, which unchecks Food too
    assert_equal 2, build_filter([ @groceries.id, @rent.id ]).selected_count
    assert_equal 1, build_filter([ Category::UNCATEGORIZED_FILTER_VALUE ]).selected_count
  end

  private
    def build_filter(category_ids)
      IncomeStatement::ExpenseCategoryFilter.new(IncomeStatement.new(@family), periods: [ @period ], category_ids: category_ids)
    end
end
