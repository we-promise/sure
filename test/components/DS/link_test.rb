require "test_helper"

class DS::LinkTest < ViewComponent::TestCase
  # The dashboard's desktop Customize link is icon-only and marked
  # `hidden lg:inline-flex`. Icon-only sizes used to add `inline-flex`
  # themselves, which beats `hidden`, so phones showed it next to the
  # mobile one.
  test "an icon-only link marked hidden stays hidden below its breakpoint" do
    render_inline(DS::Link.new(href: "/", icon: "layout-grid", variant: "outline", class: "hidden lg:inline-flex"))

    classes = page.find("a")[:class].split
    assert_includes classes, "hidden"
    assert_includes classes, "lg:inline-flex"
    refute_includes classes, "inline-flex"
  end

  test "a text link marked hidden keeps its alignment and gap for when it shows" do
    render_inline(DS::Link.new(href: "/", icon: "plus", text: "New", class: "hidden md:inline-flex"))

    classes = page.find("a")[:class].split
    assert_includes classes, "items-center"
    assert_includes classes, "gap-1"
    refute_includes classes, "inline-flex"
  end

  test "an icon-only link without a display override is a centred inline-flex box" do
    render_inline(DS::Link.new(href: "/", icon: "plus", variant: "icon"))

    classes = page.find("a")[:class].split
    assert_includes classes, "inline-flex"
    assert_includes classes, "items-center"
    assert_includes classes, "justify-center"
  end
end
