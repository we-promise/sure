require "test_helper"

class DS::ActionRowTest < ViewComponent::TestCase
  test "renders a full-width row button with an icon gutter and label" do
    render_inline(DS::ActionRow.new(text: "Create category", icon: "plus"))

    assert_selector "button[type=button].flex.w-full", text: "Create category"
    assert_selector "button > span:first-child svg"
  end

  test "keeps the gutter without an icon so labels align" do
    render_inline(DS::ActionRow.new(text: "Back"))

    assert_selector "button > span:first-child.w-5"
    assert_no_selector "button svg"
  end

  test "hidden renders hidden instead of flex, for Stimulus to reveal" do
    render_inline(DS::ActionRow.new(text: "Create", hidden: true))

    assert_selector "button.hidden", visible: :all
    assert_no_selector "button.flex", visible: :all
  end

  test "tone sets emphasis and unknown tones fall back to primary" do
    render_inline(DS::ActionRow.new(text: "Supporting", tone: :secondary))
    assert_selector "button.text-secondary"

    render_inline(DS::ActionRow.new(text: "Main", tone: :bogus))
    assert_selector "button.font-medium.text-primary"
  end

  test "block content replaces the text label and extra options reach the button" do
    render_inline(DS::ActionRow.new(data: { action: "picker#choose", parent_id: "42" }, aria: { label: "Choose parent" })) do
      "<span class='badge'>Shopping</span>".html_safe
    end

    assert_selector "button[data-action='picker#choose'][data-parent-id='42'][aria-label='Choose parent'] span.badge", text: "Shopping"
  end
end
