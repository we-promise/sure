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

  test "marker mode shows the dot by default" do
    render_inline(DS::Pill.new(label: "Beta", tone: :violet))
    assert_selector "span.inline-block.rounded-full"
  end

  test "badge mode (marker: false) is dot-less by default" do
    render_inline(DS::Pill.new(label: "Member", tone: :neutral, marker: false))
    assert_no_selector "span.inline-block.rounded-full"
  end

  test "badge mode opts back into the dot with show_dot: true" do
    render_inline(DS::Pill.new(label: "Active", tone: :success, marker: false, show_dot: true))
    assert_selector "span.inline-block.rounded-full"
  end

  test "marker mode can drop the dot with show_dot: false" do
    render_inline(DS::Pill.new(label: "Beta", tone: :violet, show_dot: false))
    assert_no_selector "span.inline-block.rounded-full"
  end

  test "custom color renders dynamic badge styles" do
    render_inline(DS::Pill.new(label: "Groceries", marker: false, custom_color: "#f97316"))

    pill = page.find("span", text: "Groceries")
    assert_includes pill[:style], "color-mix(in oklab, #f97316 10%, transparent)"
    assert_includes pill[:style], "color: #f97316"
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

  test "truncate: true lets the pill shrink and ellipsizes the label" do
    render_inline(DS::Pill.new(label: "A very long category name", marker: false, truncate: true))

    pill = page.find("span[title='A very long category name']")
    assert_includes pill[:class], "max-w-full"
    assert_includes pill[:class], "min-w-0"
    refute_includes pill[:class], "shrink-0"
    refute_includes pill[:class], "whitespace-nowrap"
    assert_selector "span.min-w-0.truncate", text: "A very long category name"
  end

  test "default pills keep intrinsic width (no truncation chrome)" do
    render_inline(DS::Pill.new(label: "Active", marker: false))

    pill = page.find("span", text: "Active")
    assert_includes pill[:class], "shrink-0"
    assert_includes pill[:class], "whitespace-nowrap"
    assert_no_selector "span.truncate"
  end

  test "label_testid stamps data-testid on the label span" do
    render_inline(DS::Pill.new(label: "Groceries", marker: false, label_testid: "category-name"))

    assert_selector "span[data-testid='category-name']", text: "Groceries"
  end

  test "icon_size passes through to the icon helper" do
    render_inline(DS::Pill.new(label: "Food", marker: false, icon: "utensils", icon_size: "sm"))

    # sm maps to w-4 h-4 in the icon helper's size table.
    assert_selector "svg.w-4.h-4"
  end
end
