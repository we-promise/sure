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

  test "forwards non-class options to the section tag" do
    render_inline(DS::Card.new(id: "budget-card")) { "Panel body" }

    assert_selector "section#budget-card"
  end

  test "the inset variant sets a panel into another surface" do
    render_inline(DS::Card.new(variant: :inset, tag: :div, id: "pin-form")) { "Form" }

    assert_selector "div#pin-form.bg-container-inset.rounded-lg.border.border-secondary.p-4", text: "Form"
    assert_no_selector ".shadow-border-xs"
  end
end
