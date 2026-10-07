require "test_helper"

class DS::ReviewRowTest < ViewComponent::TestCase
  test "renders the text and the actions in a row that queries its own width" do
    render_inline(DS::ReviewRow.new) do |row|
      row.with_actions { "<a href='/confirm'>Confirm</a>".html_safe }
      "<p>Netflix</p>".html_safe
    end

    assert_selector "div.\\@container > div.flex-col.\\@md\\:flex-row"
    assert_selector "div.min-w-0 p", text: "Netflix"
    assert_selector "div.shrink-0 a[href='/confirm']", text: "Confirm"
  end

  # An unspaced bank descriptor has a min-content width wider than a phone
  # card; without a break opportunity it scrolls the page sideways.
  test "lets an unspaced descriptor break" do
    render_inline(DS::ReviewRow.new) { "VERIZONWIRELESSPAYMENTREF1234567890" }

    assert_selector "div.min-w-0.wrap-anywhere"
  end

  test "omits the actions wrapper without actions" do
    render_inline(DS::ReviewRow.new) { "Netflix" }

    refute_selector "div.shrink-0"
  end
end
