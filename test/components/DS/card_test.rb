require "test_helper"

class DS::CardTest < ViewComponent::TestCase
  test "renders the shared card shell around yielded content" do
    render_inline(DS::Card.new) { "Panel body" }

    assert_selector "section.bg-container.rounded-xl.shadow-border-xs.p-5.flex.flex-col", text: "Panel body"
  end

  test "merges an extra class without dropping the shell" do
    render_inline(DS::Card.new(class: "items-center")) { "Panel body" }

    assert_selector "section.bg-container.items-center"
  end

  test "a panel's responsive padding, or none, replaces the default" do
    render_inline(DS::Card.new(padding: :panel)) { "Panel body" }
    assert_selector "section.px-3.py-4"
    assert_no_selector "section.p-5"

    render_inline(DS::Card.new(padding: :none)) { "Chart" }
    assert_no_selector "section.p-5"
    assert_no_selector "section.px-3"
  end

  test "forwards non-class options to the section tag" do
    render_inline(DS::Card.new(id: "budget-card")) { "Panel body" }

    assert_selector "section#budget-card"
  end
end
