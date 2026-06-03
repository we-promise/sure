require "test_helper"

class DS::SelectableCardTest < ViewComponent::TestCase
  test "renders a checkbox with title, subtitle, amount" do
    render_inline(DS::SelectableCard.new(
      name: "bucket[account_ids][]", value: "a1",
      title: "Brokerage", subtitle: "ETF", amount: "$100,000"
    ))

    assert_selector "input[type=checkbox][name='bucket[account_ids][]'][value='a1']", visible: false
    assert_text "Brokerage"
    assert_text "ETF"
    assert_text "$100,000"
  end

  test "checked renders the checkbox checked" do
    render_inline(DS::SelectableCard.new(name: "n", value: "v", title: "T", checked: true))
    assert_selector "input[type=checkbox][checked]", visible: false
  end

  test "unchecked omits the checked attribute" do
    render_inline(DS::SelectableCard.new(name: "n", value: "v", title: "T", checked: false))
    assert_no_selector "input[type=checkbox][checked]", visible: false
  end
end
