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
end
