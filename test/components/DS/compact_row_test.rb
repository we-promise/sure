require "test_helper"

class DS::CompactRowTest < ViewComponent::TestCase
  test "exposes matching header and data cell semantics" do
    [ false, true ].each do |header|
      render_inline(DS::CompactRow.new(header: header, show_date: true, show_balance: true, show_notes: false)) do |row|
        row.with_primary { "Coffee" }
      end

      assert_selector "[role='row'] > [role='#{header ? 'columnheader' : 'cell'}']", count: 6
    end
  end

  test "wraps row content in a single flex container" do
    render_inline(DS::CompactRow.new) do |row|
      row.with_primary { "Coffee" }
      row.with_amount { "$5.00" }
    end

    assert_selector "div.flex.items-center > div", minimum: 2
    assert_text "Coffee"
    assert_text "$5.00"
  end

  test "applies muted and indent styling to data rows" do
    render_inline(DS::CompactRow.new(muted: true, indent: true)) do |row|
      row.with_primary { "Transfer" }
    end

    assert_selector "div.opacity-50.text-secondary.pl-6"
  end

  test "header mode aligns with data rows via matching horizontal inset" do
    render_inline(DS::CompactRow.new(header: true, show_date: true)) do |row|
      row.with_date { "Date" }
      row.with_primary { "Transaction" }
      row.with_amount { "Amount" }
    end

    # Header outer wrapper is px-2 and data rows start at outer p-1 +
    # row px-3 (16px), so the header shell carries its own px-2.
    assert_selector "div.text-xs.uppercase.font-medium.text-secondary.px-2"
    assert_no_selector "div.py-2.px-3"
  end

  test "header checkbox column never reveals itself on mobile" do
    render_inline(DS::CompactRow.new(header: true)) do |row|
      row.with_checkbox { "<input type=\"checkbox\">".html_safe }
      row.with_primary { "Transaction" }
    end

    assert_no_selector "div.has-\\[input\\:not\\(\\.hidden\\)\\]\\:flex"
  end

  test "data row checkbox column can reveal itself on mobile via the has-[] selector" do
    render_inline(DS::CompactRow.new) do |row|
      row.with_checkbox { "<input type=\"checkbox\">".html_safe }
      row.with_primary { "Coffee" }
    end

    assert_selector "div.has-\\[input\\:not\\(\\.hidden\\)\\]\\:flex"
  end

  test "renders a placeholder when notes or category slots are not provided" do
    render_inline(DS::CompactRow.new) do |row|
      row.with_primary { "Coffee" }
    end

    assert_selector "span.text-secondary\\/40", text: "—", count: 2
  end

  test "shows the balance column only when show_balance is true" do
    render_inline(DS::CompactRow.new(show_balance: true)) do |row|
      row.with_primary { "Coffee" }
      row.with_balance { "$100.00" }
    end

    assert_text "$100.00"
  end

  test "skips the notes column entirely when show_notes is false" do
    render_inline(DS::CompactRow.new(show_notes: false)) do |row|
      row.with_primary { "Coffee" }
      row.with_amount { "$5.00" }
    end

    # Only the category placeholder remains; the notes column is gone.
    assert_selector "span.text-secondary\\/40", text: "—", count: 1
  end
end
