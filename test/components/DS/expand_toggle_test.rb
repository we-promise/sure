require "test_helper"

class DS::ExpandToggleTest < ViewComponent::TestCase
  test "renders the bare presence-marker attribute the sidebar JS selects on" do
    render_inline(DS::ExpandToggle.new(
      expand_label: "Expand all",
      collapse_label: "Collapse all",
      data: { account_sidebar_expand_all: true },
      class_name: "shrink-0"
    ))

    # `true` (not nil) is required: the tag helper drops nil-valued data keys,
    # which would omit the attribute and break the [data-...] selector.
    assert_selector "button[data-account-sidebar-expand-all]"
    assert_selector "button[data-account-sidebar-expand-all][type='button']"
    assert_selector "button[data-expand-label='Expand all']"
    assert_selector "button[data-collapse-label='Collapse all']"
    assert_selector "button[aria-expanded='false']"
    assert_selector "button > span", text: "Expand all"
  end

  test "renders the balance-sheet marker without a shrink class" do
    render_inline(DS::ExpandToggle.new(
      expand_label: "Expand all",
      collapse_label: "Collapse all",
      data: { balance_sheet_expand_all: true }
    ))

    assert_selector "button[data-balance-sheet-expand-all]"
    assert_selector "button[data-balance-sheet-expand-all][aria-expanded='false']"
    assert_selector "button > span", text: "Expand all"
  end

  test "keeps the shared outline style and the caller's extra class" do
    render_inline(DS::ExpandToggle.new(
      expand_label: "Expand all",
      collapse_label: "Collapse all",
      data: { account_sidebar_expand_all: true },
      class_name: "shrink-0"
    ))

    assert_selector "button.shrink-0.border.border-primary.bg-container.text-primary"
  end
end
