require "test_helper"

class DS::TableTest < ViewComponent::TestCase
  ROWS = [
    { name: "Rent", amount: "$1,500.00" },
    { name: "Internet", amount: "$60.00" }
  ].freeze

  test "renders a header cell per column and a cell per row and column" do
    render_table

    assert_selector "thead th[scope='col'].uppercase.text-secondary.border-b.border-divider", count: 2
    assert_selector "thead th:first-child", text: "Name"
    assert_selector "tbody tr", count: 2
    assert_selector "tbody tr:first-child td:first-child", text: "Rent"
    assert_selector "tbody tr:last-child td:last-child", text: "$60.00"
    assert_selector "tbody td.px-4.py-3", count: 4
  end

  # The header's rule separates it from the first row; every later row draws
  # its own top rule. Borders sit on the cells because the table is border-separate.
  test "draws the subdued rule above every row but the first" do
    render_table

    assert_selector "table.border-separate"
    assert_no_selector "tbody tr:first-child td.border-t"
    assert_selector "tbody tr:last-child td.border-t.border-subdued", count: 2
  end

  test "right-aligns a numeric column's header and cells with tabular digits" do
    render_table

    assert_selector "thead th:last-child.text-right.tabular-nums.whitespace-nowrap"
    assert_selector "tbody td:last-child.text-right.tabular-nums.whitespace-nowrap", count: 2
    assert_selector "tbody td:first-child.text-left", count: 2
    assert_no_selector "tbody td:first-child.tabular-nums"
  end

  test "right-aligns without the numeric treatment, and falls back to left for an unknown alignment" do
    render_inline(DS::Table.new(rows: ROWS)) do |table|
      table.with_column("Actions", align: :right) { "…" }
      table.with_column("Name", align: :nonsense) { |row| row[:name] }
    end

    assert_selector "thead th:first-child.text-right"
    assert_no_selector "thead th:first-child.tabular-nums"
    assert_selector "thead th:last-child.text-left"
  end

  test "passes each row and its index to the cell block and applies column classes to body cells only" do
    render_inline(DS::Table.new(rows: ROWS)) do |table|
      table.with_column("Device", row_header: true) { |_row, index| "Device #{index + 1}" }
      table.with_column("Amount", class: "privacy-sensitive") { |row| row[:amount] }
    end

    assert_selector "tbody th[scope='row'].font-medium", text: "Device 1"
    assert_selector "tbody th[scope='row']", text: "Device 2"
    assert_selector "tbody td.privacy-sensitive", count: 2
    assert_no_selector "thead .privacy-sensitive"
  end

  test "adds row classes from the row_class proc" do
    render_inline(DS::Table.new(rows: ROWS, row_class: ->(row) { "bg-container-inset" if row[:name] == "Rent" })) do |table|
      table.with_column("Name") { |row| row[:name] }
    end

    assert_selector "tbody tr.bg-container-inset", count: 1, text: "Rent"
  end

  test "stands alone as a card by default and sits in an inset frame on request" do
    render_table
    assert_selector "div.table-scroll.rounded-xl.shadow-border-xs"
    assert_no_selector ".bg-container-inset"

    render_table(inset: true)
    assert_selector "div.rounded-xl.bg-container-inset.p-1 > div.table-scroll.rounded-lg"
  end

  test "caps the height and makes the header cells sticky" do
    render_table(sticky_header: true)

    assert_selector "div.table-scroll.max-h-128.overflow-y-auto"
    assert_selector "thead th.sticky.top-0.z-10.bg-container", count: 2
  end

  # A scroll area needs to be focusable, and named, for a keyboard user to scroll it.
  test "makes the scroll area a named, focusable region only when given a label" do
    render_table
    assert_no_selector "[role='region']"

    render_table(label: "Payment schedule")
    assert_selector "div.table-scroll.focus-ring[role='region'][tabindex='0'][aria-label='Payment schedule']"
  end

  test "merges an extra class and forwards other options to the outer element" do
    render_table(class: "hidden @3xl:block", id: "bills-table")

    assert_selector "div#bills-table.hidden > div.table-scroll"
  end

  private
    def render_table(**options)
      render_inline(DS::Table.new(rows: ROWS, **options)) do |table|
        table.with_column("Name") { |row| row[:name] }
        table.with_column("Amount", numeric: true) { |row| row[:amount] }
      end
    end
end
