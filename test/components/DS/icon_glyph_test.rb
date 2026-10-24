require "test_helper"

class DS::IconGlyphTest < ViewComponent::TestCase
  test "renders complete multi-codepoint emoji instead of a Lucide fallback" do
    %w[👨‍👩‍👧‍👦 👩🏽‍💻 🇨🇳 1️⃣ ❤️].each do |emoji|
      render_inline(DS::IconGlyph.new(emoji: emoji, icon: "shapes", size: "sm"))
      assert_selector "[data-emoji-glyph]", text: emoji, exact_text: true
      assert_no_selector "svg"
    end
  end

  test "empty emoji preserves the Lucide icon" do
    render_inline(DS::IconGlyph.new(emoji: nil, icon: "coffee", size: "sm"))
    assert_selector "svg"
    assert_no_selector "[data-emoji-glyph]"
  end

  test "emoji text is escaped even if an unvalidated value reaches the view" do
    render_inline(DS::IconGlyph.new(emoji: "<img src=x onerror=alert(1)>", icon: "coffee"))
    assert_no_selector "img"
    assert_includes rendered_content, "&lt;img"
  end

  test "a pill retains the complete emoji and label" do
    render_inline(DS::Pill.new(label: "Synthetic category", icon: "coffee", emoji: "👩🏽‍💻", marker: false))
    assert_selector "[data-emoji-glyph]", text: "👩🏽‍💻", exact_text: true
    assert_text "Synthetic category"
    assert_no_selector "svg"
  end
  test "badge select displays the full selected emoji in its trigger and options" do
    category = categories(:food_and_drink)
    category.emoji = "👨‍👩‍👧‍👦"
    form = StyledFormBuilder.new("transaction", Transaction.new(category: category), vc_test_controller.view_context, {})
    render_inline DS::Select.new(form: form, method: :category_id, items: [ category ], selected: category.id, variant: :badge)
    assert_selector "[data-select-target='button'] [data-emoji-glyph]", text: "👨‍👩‍👧‍👦", exact_text: true
    assert_selector "[role='option'] [data-emoji-glyph]", text: "👨‍👩‍👧‍👦", exact_text: true, visible: :all
  end
end
