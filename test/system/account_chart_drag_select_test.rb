require "application_system_test_case"

class AccountChartDragSelectTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "dragging across the balance chart navigates to the dragged date range" do
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
    # fully land before issuing another visit — otherwise the two navigations
    # can race and account_url below loses to the post-login redirect.
    assert_current_path(root_path)

    visit account_url(@account)
    assert_text @account.name

    overlay = find("#lineChart .drag-select-brush .overlay", visible: :all)

    # Drive the drag off the overlay's own rendered width rather than fixed
    # pixel offsets — the chart's actual width varies with viewport/layout
    # (e.g. font metrics differ between local and CI headless Chrome), and a
    # start point that lands outside the overlay never triggers the brush.
    overlay_width = overlay.native.rect.width
    inset = 20
    start_offset = -(overlay_width / 2 - inset).round
    drag_distance = (overlay_width - (2 * inset)).round

    page.driver.browser.action
      .move_to(overlay.native, start_offset, 0)
      .click_and_hold
      .move_by(drag_distance, 0)
      .release
      .perform

    assert_current_path(%r{/accounts/#{@account.id}\?.*start_date=.*end_date=})
  end
end
