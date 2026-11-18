require "test_helper"

class DS::SummaryTileTest < ViewComponent::TestCase
  test "renders the label above the content on the inset surface" do
    render_inline(DS::SummaryTile.new(label: "Available")) { "<p class='figure'>$100</p>".html_safe }

    assert_selector "div.bg-surface-inset p.text-secondary", text: "Available"
    assert_selector "div.bg-surface-inset p.figure", text: "$100"
  end

  test "merges extra classes and attributes" do
    render_inline(DS::SummaryTile.new(label: "Next", class: "md:col-span-2", id: "next-tile")) { "x" }

    assert_selector "div#next-tile.md\\:col-span-2.bg-surface-inset"
  end
end
