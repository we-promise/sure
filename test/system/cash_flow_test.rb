require "application_system_test_case"

class CashFlowTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @month = Date.current.beginning_of_month
    parent = @user.family.categories.create!(name: "Sankey Shopping", color: "#123456")
    child = @user.family.categories.create!(name: "Sankey Groceries", parent: parent)
    account = @user.family.accounts.create!(name: "Sankey checking", currency: "USD", balance: 0, accountable: Depository.new)
    create_transaction(account: account, category: parent, amount: 100, date: @month)
    create_transaction(account: account, category: child, amount: 50, date: @month)
  end

  test "loads the API graph, expands, zooms, and preserves transaction date filters" do
    sign_in @user
    visit root_path(start_date: @month.iso8601, end_date: Date.current.iso8601)
    chart = find("#cashflow-sankey-chart [data-sankey-chart-target='chart']", match: :first)
    assert_selector "#cashflow-sankey-chart svg .sankey-link"
    assert page.evaluate_script("performance.getEntriesByType('resource').some(e => e.name.includes('/api/v1/cash_flow?'))")
    find("[data-section-key='cashflow_sankey']").hover
    find("[data-cashflow-expand-target='button']").click
    within "#cashflow-expanded-dialog" do
      assert_selector "svg .sankey-link"
    end
    page.execute_script("document.querySelector('#cashflow-expanded-dialog').close()")
    parent = chart.find("svg text", text: "Sankey Shopping", match: :first)
    parent.find(:xpath, "..").find("path").click
    assert_selector "[data-sankey-chart-target='zoomOutButton']:not([hidden])"
    find("[data-sankey-chart-target='zoomOutButton']", match: :first).click
    chart.find("svg text", text: "Sankey Groceries", match: :first).click
    assert_current_path(%r{/transactions\?})
    query = Rack::Utils.parse_nested_query(URI.parse(page.current_url).query)
    assert_equal [ "Sankey Groceries" ], query.dig("q", "categories")
    assert_equal @month.iso8601, query.dig("q", "start_date")
    assert_equal Date.current.iso8601, query.dig("q", "end_date")
  end

  test "failed load can retry and an empty range clears old chart data" do
    sign_in @user
    assert_selector "#cashflow-sankey-chart svg .sankey-link"
    page.execute_script(<<~JS)
      window.originalCashFlowFetch = window.fetch;
      window.fetch = (url, options) => String(url).includes('/api/v1/cash_flow')
        ? Promise.resolve(new Response('{}', {status: 503})) : window.originalCashFlowFetch(url, options);
      document.querySelector('[data-action="cash-flow#load"]').click();
    JS
    assert_selector "[data-cash-flow-target='error']:not([hidden])"
    assert_no_selector "[data-sankey-chart-target='chart'] svg"
    page.execute_script("window.fetch = window.originalCashFlowFetch")
    within "[data-cash-flow-target='error']" do
      click_button "Try again"
    end
    assert_selector "#cashflow-sankey-chart svg .sankey-link"
    find("h1", text: @user.first_name).hover
    page.save_screenshot("/tmp/sankey-web.png")
    visit root_path(start_date: "1900-01-01", end_date: "1900-01-02")
    assert_selector "[data-cash-flow-target='empty']:not([hidden])"
    assert_no_selector "[data-sankey-chart-target='chart'] svg"
  end
end
