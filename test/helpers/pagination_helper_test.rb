require "test_helper"

class PaginationHelperTest < ActionView::TestCase
  include PaginationHelper

  # Renders what a phone would show: kept slots, plus a "…" wherever a run of
  # pages is collapsed. Pagy marks the current page by making it a String.
  def mobile_render(series)
    plan = pagination_mobile_plan(series)
    series.each_with_index.filter_map do |item, i|
      case plan[i]
      when :visible    then item == :gap ? "…" : item.to_s
      when :collapsed  then "…"
      end
    end.join(" ")
  end

  test "collapses the middle of a long series behind an ellipsis" do
    assert_equal "1 … 5 … 760", mobile_render([ 1, :gap, 3, 4, "5", 6, 7, :gap, 760 ])
  end

  test "keeps the first and last page of a long series" do
    plan = pagination_mobile_plan([ "1", 2, 3, 4, 5, :gap, 760 ])

    assert_equal :visible, plan.first, "first page must stay"
    assert_equal :visible, plan.last, "last page must stay"
  end

  # A short series only happens when the collection has that few pages, so the
  # numbers are 1-2 digits and the row fits. Hiding here would render "1 3".
  test "leaves a short series untouched" do
    assert_equal "1 2 3", mobile_render([ "1", 2, 3 ])
  end

  # Regression: dropping pages without standing an ellipsis in their place made
  # the survivors look adjacent — "1 3 … 760" hid page 2 with no sign of it.
  test "a collapsed run away from any gap gets its own ellipsis" do
    assert_equal "1 … 3 … 760", mobile_render([ 1, 2, "3", 4, 5, :gap, 760 ])
  end

  test "a gapless series still marks the pages it drops" do
    assert_equal "1 … 6", mobile_render([ "1", 2, 3, 4, 5, 6 ])
  end

  # Pagy's own gap already stands for the skipped pages; adding another beside
  # it would render "… …".
  test "does not double up on an ellipsis Pagy already emitted" do
    assert_equal "1 … 760", mobile_render([ "1", 2, 3, 4, 5, :gap, 760 ])
  end

  test "never hides a gap or the current page" do
    plan = pagination_mobile_plan([ 1, :gap, 3, 4, "5", 6, 7, :gap, 760 ])

    assert_equal :visible, plan[1], ":gap must stay"
    assert_equal :visible, plan[4], "current page must stay"
    assert_equal :visible, plan[7], ":gap must stay"
  end

  # Whatever is collapsed, a phone must never be shown two numbers that are not
  # actually consecutive without a "…" between them.
  test "no surviving pair of pages reads as adjacent unless it is" do
    checked = 0

    [
      [ 1, 2, "3", 4, 5, :gap, 760 ],
      [ "1", 2, 3, 4, 5, 6 ],
      [ 1, :gap, 3, 4, "5", 6, 7, :gap, 760 ],
      [ 1, 2, 3, 4, "5", 6, 7 ],
      [ 1, :gap, 756, 757, 758, 759, "760" ],
      [ 1, "2", 3, 4, 5, 6 ] # current next to the first page: 1 and 2 do survive side by side
    ].each do |series|
      tokens = mobile_render(series).split(" ")
      tokens.each_cons(2) do |a, b|
        next if a == "…" || b == "…"
        checked += 1
        assert_equal a.to_i + 1, b.to_i,
          "#{series.inspect} rendered #{tokens.join(' ')}: #{a} and #{b} are not consecutive"
      end
    end

    assert_operator checked, :>, 0,
      "every pair was separated by an ellipsis, so this asserted nothing — add a series where two numbers survive side by side"
  end
end
