require "test_helper"

class NavItemViewTest < ActionView::TestCase
  test "active nav item carries aria-current=\"page\"" do
    html = render(partial: "layouts/shared/nav_item", locals: {
      name: "Transactions",
      path: "/transactions",
      icon: "credit-card",
      icon_custom: false,
      active: true
    })

    assert_includes html, "aria-current=\"page\""
  end

  test "inactive nav item omits aria-current" do
    html = render(partial: "layouts/shared/nav_item", locals: {
      name: "Transactions",
      path: "/transactions",
      icon: "credit-card",
      icon_custom: false,
      active: false
    })

    assert_not_includes html, "aria-current"
  end
end
