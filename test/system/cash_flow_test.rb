require "application_system_test_case"

class CashFlowTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @month = Date.current.beginning_of_month
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))
    parent = @user.family.categories.create!(name: "Sankey Shopping", color: "#123456")
    child = @user.family.categories.create!(name: "Sankey Groceries", parent: parent)
    account = @user.family.accounts.create!(name: "Sankey checking", currency: "USD", balance: 0, accountable: Depository.new)
    create_transaction(account: account, category: parent, amount: 100, date: @month)
    create_transaction(account: account, category: child, amount: 50, date: @month)
  end

  test "loads the dashboard graph, expands, zooms, and preserves transaction date filters" do
    sign_in @user
    visit root_path(start_date: @month.iso8601, end_date: Date.current.iso8601)
    chart = find("#cashflow-sankey [data-sankey-chart-target='chart']", match: :first)
    assert_selector "#cashflow-sankey svg .sankey-link"
    assert page.evaluate_script("performance.getEntriesByType('resource').some(e => e.name.includes('/dashboard/cash_flow?'))")
    within "#cashflow-sankey" do
      click_button "Expand", enable_aria_label: true
    end
    within "#cashflow-sankey-expanded-dialog" do
      assert_selector "svg .sankey-link"
    end
    gradients = page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll('#cashflow-sankey linearGradient')).map(g => g.id)
    JS
    assert_selector "#cashflow-sankey [data-sankey-chart-target='chart'] svg", count: 2
    assert gradients.any?
    assert_equal gradients.uniq, gradients
    assert page.evaluate_script(<<~JS)
      Array.from(document.querySelectorAll('#cashflow-sankey .sankey-link')).every(link => {
        const id = link.getAttribute('stroke').slice(5, -1);
        return link.ownerSVGElement.querySelector(`[id="${id}"]`);
      })
    JS
    page.execute_script("document.querySelector('#cashflow-sankey-expanded-dialog').close()")
    parent = chart.find("svg text", text: "Sankey Shopping", match: :first)
    parent.find(:xpath, "..").find("path").click
    assert_selector "[data-sankey-chart-target='zoomOutButton']:not([hidden])"
    find("[data-sankey-chart-target='zoomOutButton']", match: :first).click
    chart.find("svg text", text: "Sankey Groceries", match: :first).find(:xpath, "..").find("path").click
    assert_current_path(%r{/transactions\?})
    query = Rack::Utils.parse_nested_query(URI.parse(page.current_url).query)
    assert_equal [ "Sankey Groceries" ], query.dig("q", "categories")
    assert_equal @month.iso8601, query.dig("q", "start_date")
    assert_equal Date.current.iso8601, query.dig("q", "end_date")
  end

  test "bars labels Enter and Space share zoom and transaction actions" do
    sign_in @user
    [ :bar, :label, :enter, :space ].each do |activation|
      visit root_path(start_date: @month.iso8601, end_date: Date.current.iso8601)
      chart = find("#cashflow-sankey [data-sankey-chart-target='chart']", match: :first)
      parent = chart.find("g[role='button'][tabindex='0'][aria-label^='Sankey Shopping,']")
      activate_node(parent, activation)
      assert_selector "[data-sankey-chart-target='zoomOutButton']:not([hidden])"
      assert_selector "g[aria-label^='Sankey Shopping,']:focus" if [ :enter, :space ].include?(activation)
      assert_equal "false", find("[data-section-key='cashflow_sankey']")["aria-grabbed"]
      find("[data-sankey-chart-target='zoomOutButton']", match: :first).send_keys(:enter)
      assert_selector "g[aria-label^='Sankey Shopping,']:focus"
      leaf = chart.find("g[role='link'][tabindex='0'][aria-label^='Sankey Groceries,']")
      activate_node(leaf, activation)
      assert_current_path(%r{/transactions\?})
      query = Rack::Utils.parse_nested_query(URI.parse(page.current_url).query)
      assert_equal [ "Sankey Groceries" ], query.dig("q", "categories")
      assert_equal @month.iso8601, query.dig("q", "start_date")
      assert_equal Date.current.iso8601, query.dig("q", "end_date")
    end
  end

  test "closing the expanded chart returns focus to Expand after keyboard zoom" do
    sign_in @user
    [ :escape, :close_button ].each do |closing|
      visit root_path(start_date: @month.iso8601, end_date: Date.current.iso8601)
      expand = find("#cashflow-sankey [data-sankey-visualization-target='expandButton']")
      expand.send_keys(:enter)
      within "#cashflow-sankey-expanded-dialog[open]" do
        find("g[role='button'][aria-label^='Sankey Shopping,']").send_keys(:enter)
        assert_selector "g[aria-label^='Sankey Shopping,']:focus"
        if closing == :escape
          find("g:focus").send_keys(:escape)
        else
          find("button[data-action='DS--dialog#close']").click
        end
      end
      assert_no_selector "#cashflow-sankey-expanded-dialog[open]"
      assert_selector "#cashflow-sankey [data-sankey-visualization-target='expandButton']:focus"
      assert_equal "true", find("[data-section-key='cashflow_sankey']")["draggable"]
    end
  end

  test "spending without income renders the deficit cash flow expense path" do
    date = Date.new(2001, 2, 1)
    category = @user.family.categories.find_by!(name: "Sankey Shopping")
    account = @user.family.accounts.find_by!(name: "Sankey checking")
    create_transaction(account: account, category: category, amount: 160, date: date)
    sign_in @user
    visit root_path(start_date: date.iso8601, end_date: date.iso8601)
    chart = find("#cashflow-sankey [data-sankey-chart-target='chart']", match: :first)
    [ "Deficit", "Cash Flow", "Sankey Shopping" ].each do |name|
      assert_selector "#cashflow-sankey g[aria-label='#{name}, $160.00']"
    end
    links = chart.all(".sankey-link").map do |link|
      assert link["d"].present?
      link.evaluate_script("[this.__data__.source.id, this.__data__.target.id, this.__data__.value]")
    end
    assert_equal [
      [ "cash_flow_node", "expense_#{category.id}", 160 ],
      [ "deficit_node", "cash_flow_node", 160 ]
    ].sort, links.sort
  end

  test "preview structural labels and tooltips use the user locale" do
    @user.update!(locale: "es")
    sign_in @user
    chart = find("#cashflow-sankey [data-sankey-chart-target='chart']", match: :first)
    assert_selector "#cashflow-sankey svg text", text: "Flujo de caja"
    assert_selector "#cashflow-sankey svg text", text: "Déficit"
    chart.find("svg text", text: "Déficit", match: :first).hover
    assert_selector ".chart-tooltip.ph-no-capture", text: "Déficit"
    assert_selector "#cashflow-sankey svg text", text: "Sankey Groceries"
    account = @user.family.accounts.find_by!(name: "Sankey checking")
    create_transaction(account: account, amount: -1000, date: @month)
    visit root_path(start_date: @month.iso8601, end_date: Date.current.iso8601)
    assert_selector "#cashflow-sankey svg text", text: "Superávit"
  end

  test "failed load can retry and an empty range clears old chart data" do
    sign_in @user
    assert_selector "#cashflow-sankey svg .sankey-link"
    page.execute_script(<<~JS)
      window.originalCashFlowFetch = window.fetch;
      window.fetch = (url, options) => String(url).includes('/dashboard/cash_flow')
        ? Promise.resolve(new Response('{}', {status: 503})) : window.originalCashFlowFetch(url, options);
      document.querySelector('[data-action="cash-flow#load"]').click();
    JS
    assert_selector "[data-cash-flow-target='error']:not([hidden])"
    assert_no_selector "#cashflow-sankey-chart svg .sankey-link"
    assert_no_selector "[data-sankey-chart-target='chart'] svg"
    page.execute_script("window.fetch = window.originalCashFlowFetch")
    within "[data-cash-flow-target='error']" do
      click_button "Try again"
    end
    assert_selector "#cashflow-sankey svg .sankey-link"
    visit root_path(start_date: "1900-01-01", end_date: "1900-01-02")
    assert_selector "[data-cash-flow-target='empty']:not([hidden])"
    assert_no_selector "#cashflow-sankey-chart svg .sankey-link"
    assert_no_selector "[data-sankey-chart-target='chart'] svg"
  end

  test "visualization displays are counted once and expansion is tracked" do
    sign_in @user
    assert_selector "#cashflow-sankey svg .sankey-link"
    install_posthog_fake
    find("#cashflow-sankey").scroll_to(:center)
    assert_selector "#cashflow-sankey [data-sankey-chart-target='chart'] svg"
    assert_event_count "sankey_preview_displayed", 1
    page.execute_script("document.dispatchEvent(new Event('posthog:ready'))")
    assert_event_count "sankey_preview_displayed", 1

    within "#cashflow-sankey" do
      click_button "Expand", enable_aria_label: true
    end
    assert_selector "#cashflow-sankey-expanded-dialog[open] svg .sankey-link"
    assert_equal "false", find("[data-section-key='cashflow_sankey']")["draggable"]
    assert_event_count "sankey_preview_displayed", 2
    within "#cashflow-sankey-expanded-dialog" do
      find("button[data-action='DS--dialog#close']").click
    end
    assert_equal "true", find("[data-section-key='cashflow_sankey']")["draggable"]

    assert_equal [ "sankey_preview_displayed" ], page.evaluate_script("[...new Set(window.sankeyEvents.map(e => e.event))]")
  end

  test "collapsed visualizations do not count until visible and keyboard expansion preserves section order" do
    sign_in @user
    assert_selector "#cashflow-sankey svg .sankey-link"
    section = find("[data-section-key='cashflow_sankey']")
    section.find("[data-dashboard-section-target='button']").click
    assert_no_selector "#cashflow-sankey-chart"
    install_posthog_fake
    assert_event_count "sankey_preview_displayed", 0
    section.find("[data-dashboard-section-target='button']").click
    find("#cashflow-sankey").scroll_to(:center)
    assert_event_count "sankey_preview_displayed", 1
    within "#cashflow-sankey" do
      find_button("Expand", enable_aria_label: true).send_keys(:enter)
    end
    assert_selector "#cashflow-sankey-expanded-dialog[open]"
    assert_equal "false", section["aria-grabbed"]
    assert_event_count "sankey_preview_displayed", 2
  end

  test "Turbo snapshots clear graphs and floating tooltips" do
    sign_in @user
    assert_selector "#cashflow-sankey svg .sankey-link"
    install_posthog_fake
    find("#cashflow-sankey svg text", text: "Sankey Shopping", match: :first).hover
    assert_selector ".chart-tooltip.ph-no-capture", text: "Sankey Shopping"
    snapshot = page.evaluate_script(<<~JS)
      (() => {
        document.dispatchEvent(new Event('turbo:before-cache'));
        const copy = document.body.cloneNode(true);
        return {
          previewGraphs: copy.querySelectorAll('#cashflow-sankey svg .sankey-link').length,
          tooltips: copy.querySelectorAll('.chart-tooltip.ph-no-capture').length
        };
      })()
    JS
    assert_equal({ "previewGraphs" => 0, "tooltips" => 0 }, snapshot)
    assert_event_count "survey sent", 0
  end

  test "self-hosted displays use only the separate project" do
    with_self_hosting do
      sign_in @user
      visit root_path(start_date: @month.iso8601, end_date: Date.current.iso8601)
      assert_selector "#cashflow-sankey svg .sankey-link"
      install_posthog_fake
      page.execute_script(<<~JS)
        const shared = window.posthog;
        window.posthog = {
          __loaded: true,
          has_opted_out_capturing: () => false,
          capture: () => { throw new Error('Wrong analytics destination'); },
          sankeyFeedback: shared
        };
        document.dispatchEvent(new Event('posthog:ready'));
      JS
      find("#cashflow-sankey").scroll_to(:center)
      assert_event_count "sankey_preview_displayed", 1
      within "#cashflow-sankey" do
        click_button "Expand", enable_aria_label: true
      end
      assert_event_count "sankey_preview_displayed", 2
      find("#cashflow-sankey-expanded-dialog").find("button[data-action='DS--dialog#close']").click
      assert_equal [ "sankey_preview_displayed" ], page.evaluate_script("[...new Set(window.sankeyEvents.map(e => e.event))]")
    end
  end

  private
    def activate_node(node, activation)
      case activation
      when :bar then node.find("path").click
      when :label then node.find("text", match: :first).click
      else node.send_keys(activation)
      end
    end

    def install_posthog_fake
      page.execute_script(<<~JS)
        window.sankeyEvents = [];
        window.posthog = {
          __loaded: true,
          has_opted_out_capturing: () => false,
          capture: (event, properties) => { window.sankeyEvents.push({event, properties}); return {}; },
        };
        document.querySelector('#cashflow-sankey').setAttribute('data-sankey-visualization-feedback-key-value', 'test-public-token');
        document.dispatchEvent(new Event('posthog:ready'));
      JS
    end

    def assert_event_count(event, count)
      assert_selector "body" do
        page.evaluate_script("window.sankeyEvents.filter(e => e.event === #{event.to_json}).length") == count
      end
    end
end
