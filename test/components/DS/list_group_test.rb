require "test_helper"

class DS::ListGroupTest < ViewComponent::TestCase
  test "wraps content in a Card with divide-y and token-correct divider colors" do
    render_inline(DS::ListGroup.new) do
      "<div>a</div><div>b</div>".html_safe
    end

    card = page.find("div", class: "bg-container")
    assert_includes card[:class], "divide-y"
    assert_includes card[:class], "divide-alpha-black-100"
    assert_includes card[:class], "theme-dark:divide-alpha-white-100"
  end

  test "defaults to inner level and overflow_hidden so list rows clip cleanly" do
    render_inline(DS::ListGroup.new) { "<div>row</div>".html_safe }

    card = page.find("div", class: "bg-container")
    assert_includes card[:class], "rounded-lg"
    assert_includes card[:class], "overflow-hidden"
  end

  test "level passes through to the underlying Card" do
    render_inline(DS::ListGroup.new(level: :tight)) { "<div>row</div>".html_safe }

    card = page.find("div", class: "bg-container")
    assert_includes card[:class], "rounded-md"
  end

  test "default padding is :none so item padding owns spacing" do
    render_inline(DS::ListGroup.new) { "<div>row</div>".html_safe }

    card = page.find("div", class: "bg-container")
    refute_match(/\bp-\d+\b/, card[:class])
  end
end
