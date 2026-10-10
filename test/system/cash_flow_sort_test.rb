require "application_system_test_case"

class CashFlowSortTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    @month = Date.current.beginning_of_month
    account = @user.family.accounts.first
    { "Sort Small" => 30, "Sort Large" => 3000, "Sort Medium" => 300 }.each do |name, amount|
      category = @user.family.categories.create!(name: name, color: "#123456")
      create_transaction(account: account, name: "#{name} spend", amount: amount, category: category, date: @month)
    end
    page.current_window.resize_to(1400, 1000)
  end

  test "sorting the preview Sankey orders each column by amount and is remembered" do
    visit root_path(start_date: @month.iso8601, end_date: Date.current.iso8601)
    chart = find("#cashflow-preview [data-controller='preview-sankey-chart']", match: :first)
    assert chart.has_css?("svg .sankey-link")

    chart.click_button "Smallest first"
    assert_column_order(:ascending)

    chart.click_button "Largest first"
    assert_column_order(:descending)

    visit root_path(start_date: @month.iso8601, end_date: Date.current.iso8601)
    chart = find("#cashflow-preview [data-controller='preview-sankey-chart']", match: :first)
    assert chart.has_css?("svg .sankey-link")
    assert chart.has_css?("button[data-sort-order='descending'][aria-pressed='true']")
    assert_column_order(:descending)
  end

  private
    # Reads the rendered layout (d3 binds each node's datum to its <g>) and
    # checks every column with 2+ nodes is ordered top-to-bottom by value.
    def assert_column_order(direction)
      # A redraw fades the old drawing out and appends a new one, stamped with
      # its sort order, so wait for that one and read it.
      svg = "#cashflow-preview [data-preview-sankey-chart-target='chart'] svg[data-sort-order='#{direction}']"
      assert page.has_css?("#{svg} .sankey-link", wait: 5)
      columns = page.evaluate_script(<<~JS)
        (() => {
          const svg = document.querySelector(#{svg.to_json});
          const byLayer = {};
          svg.querySelectorAll("g > g").forEach((g) => {
            const d = g.__data__;
            if (!d || d.layer === undefined || d.value === undefined) return;
            (byLayer[d.layer] ||= []).push({ y: d.y0, value: d.value });
          });
          return Object.values(byLayer)
            .filter((col) => col.length > 1)
            .map((col) => col.sort((a, b) => a.y - b.y).map((n) => n.value));
        })()
      JS

      assert columns.any?, "expected at least one column with several nodes"
      columns.each do |values|
        expected = direction == :ascending ? values.sort : values.sort.reverse
        assert_equal expected, values, "column not #{direction}: #{values.inspect}"
      end
    end
end
