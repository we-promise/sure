require "test_helper"

class DS::DetailRowTest < ViewComponent::TestCase
  test "renders the label and value as a dt/dd pair" do
    render_inline(DS::DetailRow.new(label: "Payee", value: "Whole Foods"))

    assert_selector "div.flex.justify-between.items-start"
    assert_selector "dt.text-secondary.text-sm", text: "Payee"
    assert_selector "dd.text-primary.text-right.break-words", text: "Whole Foods"
  end

  test "renders a value slot when the value needs its own markup" do
    render_inline(DS::DetailRow.new(label: "Account")) do |row|
      row.with_value { "<a href='/accounts/1'>Checking</a>".html_safe }
    end

    assert_selector "dd a[href='/accounts/1']", text: "Checking"
  end

  # Both wrapping and truncating need the cell to shrink below its min-content
  # width first, which a flex item will not do on its own.
  test "wraps by default and truncates on request, and can shrink either way" do
    render_inline(DS::DetailRow.new(label: "Raw", value: "a very long provider value"))
    assert_selector "dd.min-w-0.break-words"
    refute_selector "dd.truncate"

    render_inline(DS::DetailRow.new(label: "Raw", value: "a very long provider value", truncate: true))
    assert_selector "dd.min-w-0.truncate"
    refute_selector "dd.break-words"
  end

  test "accepts an alignment and falls back to start for an unknown one" do
    render_inline(DS::DetailRow.new(label: "Memo", value: "x", align: :center))
    assert_selector "div.items-center"

    render_inline(DS::DetailRow.new(label: "Memo", value: "x", align: :nonsense))
    assert_selector "div.items-start"
  end

  test "merges an extra class without dropping the base classes" do
    render_inline(DS::DetailRow.new(label: "Memo", value: "x", class: "pt-2"))

    assert_selector "div.flex.justify-between.pt-2"
  end

  test "adds value classes and forwards non-class options to the row" do
    render_inline(DS::DetailRow.new(label: "Amount", value: "$10", value_class: "privacy-sensitive", id: "amount-row"))

    assert_selector "div#amount-row"
    assert_selector "dd.privacy-sensitive", text: "$10"
  end
end
