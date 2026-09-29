require "application_system_test_case"

class DashboardChartDragSelectTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
  end

  test "dragging across the net worth chart navigates to the dragged date range instead of reordering the card" do
    sign_in @user

    original_order = page.all("[data-section-key]").map { |el| el["data-section-key"] }

    # The net worth chart sits inside a `<section draggable="true">` used by
    # dashboard-sortable for card reordering. Without an explicit
    # `draggable="false"` on the chart container, this same gesture would be
    # hijacked by the native HTML5 drag-and-drop instead of the chart's brush.
    drag_across find("#netWorthChart .drag-select-brush .overlay", visible: :all)

    assert_current_path(%r{/\?.*start_date=.*end_date=})

    # Some sections (e.g. the outflows donut) hide themselves when the
    # selected range has no matching data — that's expected, so only assert
    # that whatever sections persist keep their relative order (i.e. nothing
    # got dragged to a new position).
    new_order = page.all("[data-section-key]").map { |el| el["data-section-key"] }
    common_keys = original_order & new_order
    assert_equal common_keys, new_order & common_keys
  end
end
