require "test_helper"

class DS::SearchResultTest < ViewComponent::TestCase
  test "renders the title and subtitle in a link" do
    render_inline(DS::SearchResult.new(href: "/settings/security", title: "Security", subtitle: "Account"))

    assert_selector "a[href='/settings/security']"
    assert_selector "a [data-slot=title].text-primary", text: "Security"
    assert_selector "a [data-slot=subtitle].text-secondary", text: "Account"
  end

  test "renders the icon when given one" do
    render_inline(DS::SearchResult.new(href: "/", title: "Security", icon: "shield"))

    assert_selector "[data-slot=icon] svg"
  end

  test "renders an empty row for a script to fill in" do
    render_inline(DS::SearchResult.new(href: "#"))

    assert_selector "[data-slot=icon]:empty"
    assert_selector "[data-slot=title]:empty"
    assert_selector "[data-slot=subtitle]:empty"
  end

  test "merges caller classes and forwards other attributes" do
    render_inline(DS::SearchResult.new(href: "/", title: "A", class: "extra", role: "option", aria: { selected: "false" }, data: { turbo: false }))

    assert_selector "a.extra.rounded-lg[role=option][aria-selected=false][data-turbo=false]"
  end
end
