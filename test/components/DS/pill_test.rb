require "test_helper"

class DS::PillTest < ViewComponent::TestCase
  test "marker mode (default) renders uppercase sub-12px chrome with rounded-md" do
    render_inline(DS::Pill.new(label: "Beta", tone: :violet))

    pill = page.find("span", text: "Beta")
    assert_includes pill[:class], "uppercase"
    # Marker keeps sub-12px text via arbitrary value (intentional — see component docs).
    assert_match(/text-\[1[01]px\]/, pill[:class])
    # Marker uses rounded-md (chip shape).
    assert_includes pill[:class], "rounded-md"
    refute_includes pill[:class], "rounded-full"
  end

  test "marker: false renders normal-case DS-scale chrome with rounded-full" do
    render_inline(DS::Pill.new(label: "Active", tone: :success, marker: false))

    pill = page.find("span", text: "Active")
    refute_includes pill[:class], "uppercase"
    # Badge mode snaps to text-xs / text-sm — no sub-12px arbitrary values.
    assert_match(/text-(xs|sm)/, pill[:class])
    refute_match(/text-\[1[01]px\]/, pill[:class])
    # Badge uses rounded-full to match the existing _status_pill / _maturity_badge convention.
    assert_includes pill[:class], "rounded-full"
    refute_includes pill[:class], "rounded-md"
  end

  test "semantic tone aliases resolve to visual palette tones" do
    {
      success:     :green,
      warning:     :amber,
      error:       :red,
      destructive: :red,
      info:        :indigo,
      neutral:     :gray
    }.each do |alias_name, expected_visual|
      pill = DS::Pill.new(label: "x", tone: alias_name)
      assert_equal expected_visual, pill.tone, "Expected #{alias_name} → #{expected_visual}, got #{pill.tone}"
    end
  end

  test "unknown tone falls back to violet" do
    pill = DS::Pill.new(label: "x", tone: :nonexistent)
    assert_equal :violet, pill.tone
  end

  test "red tone palette resolves to red-* tokens" do
    pill = DS::Pill.new(label: "Failed", tone: :error)
    assert_includes pill.palette[:dot], "color-red-500"
    assert_includes pill.palette[:bg], "color-red-50"
  end

  test "icon option renders glyph in place of dot" do
    render_inline(DS::Pill.new(label: "Syncing", tone: :info, marker: false, icon: "loader"))

    # Lucide icon helper renders the inline SVG; verifying we see at least one <svg>
    # is enough — the icon helper is covered by its own tests.
    assert_selector "svg"
    # And the dot is suppressed when an icon takes its place. The dot is an
    # `inline-block` span (parent pill is `inline-flex`), so target it by
    # `inline-block.rounded-full` to avoid matching the parent pill.
    assert_no_selector "span.inline-block.rounded-full"
  end
end
