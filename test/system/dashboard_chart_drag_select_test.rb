require "application_system_test_case"

class DashboardChartDragSelectTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
  end

  test "dragging across the net worth chart navigates to the dragged date range instead of reordering the card" do
    # The shared `sign_in` helper looks up fields by their English label text,
    # which breaks whenever the browser negotiates a non-English locale. Sign
    # in via field type instead so this test doesn't depend on the browser's
    # language.
    visit new_session_path
    within %(form[action='#{sessions_path}']) do
      find("input[type='email']").set(@user.email)
      find("input[type='password']").set(user_password_test)
      find("[type='submit']").click
    end

    # The login form is a plain (non-Turbo) POST, so wait for its redirect to
    # fully land before issuing another visit.
    assert_current_path(root_path)

    visit root_path
    original_order = page.all("[data-section-key]").map { |el| el["data-section-key"] }

    overlay = find("#netWorthChart .drag-select-brush .overlay", visible: :all)

    # Drive the drag off the overlay's own rendered width rather than fixed
    # pixel offsets — the chart's actual width varies with viewport/layout
    # (e.g. font metrics differ between local and CI headless Chrome), and a
    # start point that lands outside the overlay never triggers the brush.
    overlay_width = overlay.native.rect.width
    inset = 20
    start_offset = -(overlay_width / 2 - inset).round
    drag_distance = (overlay_width - (2 * inset)).round

    # The net worth chart sits inside a `<section draggable="true">` used by
    # dashboard-sortable for card reordering. Without an explicit
    # `draggable="false"` on the chart container, this same gesture would be
    # hijacked by the native HTML5 drag-and-drop instead of the chart's brush.
    page.driver.browser.action
      .move_to(overlay.native, start_offset, 0)
      .click_and_hold
      .move_by(drag_distance, 0)
      .release
      .perform

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
