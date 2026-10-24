require "test_helper"

class DS::TooltipTest < ViewComponent::TestCase
  test "uses custom trigger content when provided" do
    trigger = '<span class="reconciliation-indicator"></span>'.html_safe

    render_inline(DS::Tooltip.new(text: "Matched", as: :span, trigger_content: trigger))

    assert_selector "span.reconciliation-indicator"
    assert_no_selector "svg"
    assert_selector "[aria-describedby^='tooltip-']"
    assert_selector "[role='tooltip']", text: "Matched"
  end

  test "defaults to the inverse surface with an icon trigger" do
    render_inline(DS::Tooltip.new(text: "Helpful hint"))

    assert_selector "button[aria-describedby]"
    assert_selector "[role=tooltip].bg-inverse", visible: :all, text: "Helpful hint"
    assert_selector "[role=tooltip] .text-inverse", visible: :all
  end

  test "surface variant uses the themed card" do
    render_inline(DS::Tooltip.new(text: "Card content", variant: :surface))

    assert_selector "[role=tooltip].chart-tooltip", visible: :all, text: "Card content"
    assert_selector "[role=tooltip] .text-primary", visible: :all
    assert_no_selector "[role=tooltip].bg-inverse", visible: :all
  end

  test "custom trigger replaces the icon" do
    render_inline(DS::Tooltip.new(text: "Full name")) do |tooltip|
      tooltip.with_trigger { "Trigger pill" }
    end

    assert_selector "span[aria-describedby]", text: "Trigger pill"
    assert_no_selector "button"
    assert_selector "[role=tooltip]", visible: :all, text: "Full name"
  end

  test "rejects unknown variants" do
    assert_raises(ArgumentError) { DS::Tooltip.new(variant: :neon) }
  end
end
