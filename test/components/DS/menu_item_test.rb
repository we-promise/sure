require "test_helper"

class DS::MenuItemTest < ViewComponent::TestCase
  test "selectable item reserves a fixed-width check gutter and shows the check when selected" do
    render_inline(DS::MenuItem.new(variant: :link, text: "30D", href: "/", selected: true))

    assert_selector "span.shrink-0.w-5", count: 1
    assert_selector "span.shrink-0.w-5 svg", count: 1
    assert_text "30D"
  end

  test "selectable item keeps the reserved gutter (no glyph) when not selected" do
    render_inline(DS::MenuItem.new(variant: :link, text: "90D", href: "/", selected: false))

    # Gutter still present so text stays aligned with the selected row...
    assert_selector "span.shrink-0.w-5", count: 1
    # ...but no check glyph is drawn.
    assert_no_selector "span.shrink-0.w-5 svg"
  end

  test "plain action item (selected: nil) renders no check gutter" do
    render_inline(DS::MenuItem.new(variant: :link, text: "Edit", href: "/", icon: "pencil-line"))

    assert_no_selector "span.shrink-0.w-5"
    assert_text "Edit"
  end
end
