require "application_system_test_case"

# A bill's "..." menu opens against its button. The All bills list sits in a
# size container, and floating-ui 0.2.9 took any `container-type` ancestor for
# the containing block of a `position: fixed` menu, so it subtracted the
# container's offset and the menu opened a container's width away, mid-page.
class BillMenuPositionTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))

    due = Date.current + 10
    @user.family.recurring_transactions.create!(
      name: "City Water", account: accounts(:depository), amount: 80, currency: "USD",
      expected_day_of_month: due.day, last_occurrence_date: due - 1.month,
      next_expected_date: due, status: "active"
    )
  end

  test "on a desktop, the All bills menu opens against its button, right edges aligned" do
    button, menu = open_first_menu

    # Not near the button: on it. The defect put the right edge 445px left of
    # the button's, so a loose tolerance would still prove the fix.
    assert_in_delta button["right"], menu["right"], 1, "menu is not aligned to its button"
    assert_adjacent button, menu
  end

  test "on a phone, the All bills menu opens directly against its button" do
    page.current_window.resize_to(375, 812)
    button, menu = open_first_menu

    # The full-width branch sets left and width itself, so only the top comes
    # from floating-ui; the defect moved the top 270px above the button.
    assert_adjacent button, menu
  ensure
    reset_viewport
  end

  private
    def open_first_menu
      visit bills_url(view: "all")
      # A row's menu, not the page header's, which sits outside the container.
      button = find(%q(.\@container [data-DS--menu-target="button"]), match: :first)
      button.click
      menu = find("##{button["aria-controls"]}", visible: true)

      rect = ->(node) { node.evaluate_script("(r => ({ left: r.left, top: r.top, right: r.right, bottom: r.bottom }))(this.getBoundingClientRect())") }
      [ rect.(button), rect.(menu) ]
    end

    # flip() may put the menu above the button when there is no room below,
    # so accept either side, but only a gap the size of the offset.
    def assert_adjacent(button, menu)
      gap = menu["top"] >= button["bottom"] ? menu["top"] - button["bottom"] : button["top"] - menu["bottom"]
      assert gap.between?(0, 20), "menu is #{gap}px from its button, expected it beside it (button #{button}, menu #{menu})"
    end
end
