require "test_helper"

class PaginationHelperTest < ActionView::TestCase
  include PaginationHelper

  # Pagy marks the current page by making it a String; other pages are
  # Integers and elisions are :gap.
  test "hides the middle pages of a long series on small screens" do
    series = [ 1, :gap, 3, 4, "5", 6, 7, :gap, 760 ]

    kept = series.each_index.reject { |i| pagination_item_class(series, i) }

    assert_equal [ 0, 1, 4, 7, 8 ], kept
    assert_equal [ 1, :gap, "5", :gap, 760 ], kept.map { |i| series[i] },
      "a phone should keep first, last, current and the gaps"
  end

  test "keeps the first and last page of a long series" do
    series = [ "1", 2, 3, 4, 5, :gap, 760 ]

    assert_nil pagination_item_class(series, 0), "first page must stay"
    assert_nil pagination_item_class(series, 6), "last page must stay"
    assert_equal "hidden sm:inline-flex", pagination_item_class(series, 2)
  end

  # A short series only happens when the collection has that few pages, so the
  # numbers are 1-2 digits and the row fits. Hiding here would render "1 3".
  test "leaves a short series untouched" do
    series = [ "1", 2, 3 ]

    series.each_index { |i| assert_nil pagination_item_class(series, i) }
  end

  test "never hides a gap or the current page" do
    series = [ 1, :gap, 3, 4, "5", 6, 7, :gap, 760 ]

    assert_nil pagination_item_class(series, 1), ":gap must stay"
    assert_nil pagination_item_class(series, 4), "current page must stay"
    assert_nil pagination_item_class(series, 7), ":gap must stay"
  end
end
