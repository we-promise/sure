require "test_helper"

class DS::CardTest < ViewComponent::TestCase
  test "outer level renders rounded-xl with default md padding and bg-container chrome" do
    render_inline(DS::Card.new) { "body" }

    card = page.find("div", text: "body")
    assert_includes card[:class], "rounded-xl"
    assert_includes card[:class], "bg-container"
    assert_includes card[:class], "shadow-border-xs"
    assert_includes card[:class], "p-4"
    refute_includes card[:class], "rounded-lg"
    refute_includes card[:class], "rounded-md"
  end

  test "inner level downgrades radius to rounded-lg" do
    render_inline(DS::Card.new(level: :inner)) { "body" }

    card = page.find("div", text: "body")
    assert_includes card[:class], "rounded-lg"
    refute_includes card[:class], "rounded-xl"
  end

  test "tight level downgrades radius to rounded-md" do
    render_inline(DS::Card.new(level: :tight)) { "body" }

    card = page.find("div", text: "body")
    assert_includes card[:class], "rounded-md"
    refute_includes card[:class], "rounded-xl"
    refute_includes card[:class], "rounded-lg"
  end

  test "padding: :none omits padding utility entirely" do
    render_inline(DS::Card.new(padding: :none)) { "body" }

    card = page.find("div", text: "body")
    refute_match(/\bp-\d+\b/, card[:class])
  end

  test "overflow_hidden flag adds overflow-hidden utility" do
    render_inline(DS::Card.new(overflow_hidden: true)) { "body" }

    card = page.find("div", text: "body")
    assert_includes card[:class], "overflow-hidden"
  end

  test "unknown level falls back to :outer" do
    render_inline(DS::Card.new(level: :nonexistent)) { "body" }

    card = page.find("div", text: "body")
    assert_includes card[:class], "rounded-xl"
  end

  test "passthrough class merges with container classes" do
    render_inline(DS::Card.new(class: "custom-extra")) { "body" }

    card = page.find("div", text: "body")
    assert_includes card[:class], "custom-extra"
    assert_includes card[:class], "bg-container"
  end

  test "tag option swaps the wrapping element" do
    render_inline(DS::Card.new(tag: :section)) { "body" }

    assert_selector "section", text: "body"
  end
end
