require "test_helper"

class DS::SectionTest < ViewComponent::TestCase
  test "heads a card of rows with the title and count, in an inset shell" do
    render_inline(DS::Section.new(title: "Needs review", count: 2)) { "<p>Netflix</p>".html_safe }

    assert_selector "section.rounded-xl.bg-container-inset.p-1 .uppercase.text-secondary", text: /Needs review\s*·\s*2/
    assert_selector "h2", text: "Needs review"
    assert_selector "[aria-hidden='true']", text: "·"
    # Straight in the shell, with nothing padding it narrower than other cards.
    assert_selector "section.bg-container-inset.p-1 > div.bg-container.rounded-lg.shadow-border-xs > p", text: "Netflix"
    assert_no_selector "details, svg"
  end

  test "ends the heading row with the aside" do
    render_inline(DS::Section.new(title: "Needs attention", count: 1)) do |section|
      section.with_aside { "<p>$120.00 overdue</p>".html_safe }
      "<p>Rent</p>".html_safe
    end

    assert_selector :xpath, "//div[h2]/following-sibling::*[1]", text: "$120.00 overdue"
  end

  test "leaves the shell to a parent that stacks several sections" do
    render_inline(DS::Section.new(title: "Later", count: 1, inset: false)) { "<p>Rent</p>".html_safe }

    assert_no_selector ".bg-container-inset"
    assert_selector "section h2", text: "Later"
    assert_selector "div.bg-container.rounded-lg > p", text: "Rent"
  end

  # With both sidebars open a list is phone-width at a desktop viewport, so
  # rows size themselves against the card, not the screen.
  test "makes the card the query container for its rows" do
    render_inline(DS::Section.new(title: "This month", count: 1)) { "<p>Rent</p>".html_safe }

    assert_selector "div.\\@container.bg-container > p", text: "Rent"
  end

  # A list that can run long folds away under its heading, and stays folded.
  test "a collapsible section folds its card under the heading and remembers it" do
    render_inline(DS::Section.new(title: "Possible new bills", count: 4, collapsible: true, persist_key: "bills-suggested")) do |section|
      section.with_aside { "<p>Tap to review</p>".html_safe }
      "<p>Hulu</p>".html_safe
    end

    assert_selector "section.bg-container-inset.p-1 > details[open][data-controller='persisted-disclosure'][data-persisted-disclosure-key-value='bills-suggested']"
    assert_selector "summary svg"
    assert_selector "summary h2", text: "Possible new bills"
    assert_selector "summary p", text: "Tap to review"
    assert_selector "details .bg-container p", text: "Hulu"
    assert_no_selector "summary .bg-container"
  end

  test "refuses a persist key on a section that can't collapse" do
    assert_raises(ArgumentError) { DS::Section.new(title: "Needs review", count: 1, persist_key: "bills-review") }
  end
end
