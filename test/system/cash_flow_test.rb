require "application_system_test_case"

class CashFlowTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @month = Date.current.beginning_of_month
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    parent = @user.family.categories.create!(name: "Sankey Shopping", color: "#123456")
    child = @user.family.categories.create!(name: "Sankey Groceries", parent: parent)
    account = @user.family.accounts.create!(name: "Sankey checking", currency: "USD", balance: 0, accountable: Depository.new)
    create_transaction(account: account, category: parent, amount: 100, date: @month)
    create_transaction(account: account, category: child, amount: 50, date: @month)
  end

  test "loads the API graph, expands, zooms, and preserves transaction date filters" do
    sign_in @user
    visit root_path(start_date: @month.iso8601, end_date: Date.current.iso8601)
    chart = find("#cashflow-preview [data-preview-sankey-chart-target='chart']", match: :first)
    assert_selector "#cashflow-preview svg .sankey-link"
    assert page.evaluate_script("performance.getEntriesByType('resource').some(e => e.name.includes('/api/v1/cash_flow?'))")
    within "#cashflow-preview" do
      click_button "Expand"
    end
    within "#cashflow-preview-expanded-dialog" do
      assert_selector "svg .sankey-link"
    end
    page.execute_script("document.querySelector('#cashflow-preview-expanded-dialog').close()")
    parent = chart.find("svg text", text: "Sankey Shopping", match: :first)
    parent.find(:xpath, "..").find("path").click
    assert_selector "[data-preview-sankey-chart-target='zoomOutButton']:not([hidden])"
    find("[data-preview-sankey-chart-target='zoomOutButton']", match: :first).click
    chart.find("svg text", text: "Sankey Groceries", match: :first).click
    assert_current_path(%r{/transactions\?})
    query = Rack::Utils.parse_nested_query(URI.parse(page.current_url).query)
    assert_equal [ "Sankey Groceries" ], query.dig("q", "categories")
    assert_equal @month.iso8601, query.dig("q", "start_date")
    assert_equal Date.current.iso8601, query.dig("q", "end_date")
  end

  test "failed load can retry and an empty range clears old chart data" do
    sign_in @user
    assert_selector "#cashflow-preview svg .sankey-link"
    page.execute_script(<<~JS)
      window.originalCashFlowFetch = window.fetch;
      window.fetch = (url, options) => String(url).includes('/api/v1/cash_flow')
        ? Promise.resolve(new Response('{}', {status: 503})) : window.originalCashFlowFetch(url, options);
      document.querySelector('[data-action="cash-flow#load"]').click();
    JS
    assert_selector "[data-cash-flow-target='error']:not([hidden])"
    assert_selector "#cashflow-sankey-chart svg .sankey-link"
    assert_no_selector "[data-preview-sankey-chart-target='chart'] svg"
    page.execute_script("window.fetch = window.originalCashFlowFetch")
    within "[data-cash-flow-target='error']" do
      click_button "Try again"
    end
    assert_selector "#cashflow-preview svg .sankey-link"
    visit root_path(start_date: "1900-01-01", end_date: "1900-01-02")
    assert_selector "[data-cash-flow-target='empty']:not([hidden])"
    assert_no_selector "#cashflow-sankey-chart svg .sankey-link"
    assert_no_selector "[data-preview-sankey-chart-target='chart'] svg"
  end

  test "preview displays are counted once and feedback uses PostHog survey question IDs" do
    sign_in @user
    assert_selector "#cashflow-preview svg .sankey-link"
    install_posthog_fake
    find("#cashflow-preview").scroll_to(:center)
    assert_selector "#cashflow-preview [data-preview-sankey-chart-target='chart'] svg"
    assert_event_count "sankey_preview_displayed", 1
    page.execute_script("document.dispatchEvent(new Event('posthog:ready'))")
    assert_event_count "sankey_preview_displayed", 1

    within "#cashflow-preview" do
      click_button "Expand"
    end
    assert_selector "#cashflow-preview-expanded-dialog[open] svg .sankey-link"
    assert_equal "false", find("[data-section-key='cashflow_sankey']")["draggable"]
    assert_event_count "sankey_preview_displayed", 2
    within "#cashflow-preview-expanded-dialog" do
      find("button[data-action='DS--dialog#close']").click
    end
    assert_equal "true", find("[data-section-key='cashflow_sankey']")["draggable"]

    [ "Looks right", "Something looks wrong" ].each_with_index do |rating, index|
      within "#cashflow-preview" do
        click_button rating
      end
      within "#cashflow-preview-feedback-dialog" do
        fill_in "What did not show correctly?", with: "Labels overlap"
        click_button "Send feedback"
        assert_text "Thanks for helping improve the chart!"
        find("button[data-action='DS--dialog#close']").click
      end
      assert_event_count "survey sent", index + 1
      response = page.evaluate_script("window.sankeyEvents.filter(e => e.event === 'survey sent').at(-1).properties")
      assert_equal rating, response.fetch("$survey_response_rating-id")
      assert_equal "Labels overlap", response.fetch("$survey_response_feedback-id")
      assert_equal "test-survey", response.fetch("$survey_id")
    end
    assert_event_count "survey shown", 2
    assert_event_count "survey dismissed", 0
  end

  test "dismissing feedback does not submit it and absent analytics keeps both charts usable" do
    sign_in @user
    assert_selector "#cashflow-preview svg .sankey-link"
    within "#cashflow-preview" do
      click_button "Something looks wrong"
    end
    within "#cashflow-preview-feedback-dialog" do
      assert_text "Feedback isn't available right now"
      find("button[data-action='DS--dialog#close']").click
    end
    install_posthog_fake
    within "#cashflow-preview" do
      click_button "Something looks wrong"
    end
    within "#cashflow-preview-feedback-dialog" do
      fill_in "What did not show correctly?", with: "Not submitted"
      find("button[data-action='DS--dialog#close']").click
    end
    assert_event_count "survey dismissed", 1
    assert_event_count "survey sent", 0
    assert_selector "#cashflow-sankey-chart svg .sankey-link"
    assert_selector "#cashflow-preview svg .sankey-link"
  end

  test "collapsed previews do not count until visible and keyboard expansion preserves section order" do
    sign_in @user
    assert_selector "#cashflow-preview svg .sankey-link"
    section = find("[data-section-key='cashflow_sankey']")
    section.find("[data-dashboard-section-target='button']").click
    assert_no_selector "#cashflow-preview"
    install_posthog_fake
    assert_event_count "sankey_preview_displayed", 0
    section.find("[data-dashboard-section-target='button']").click
    find("#cashflow-preview").scroll_to(:center)
    assert_event_count "sankey_preview_displayed", 1
    within "#cashflow-preview" do
      find_button("Expand").send_keys(:enter)
    end
    assert_selector "#cashflow-preview-expanded-dialog[open]"
    assert_equal "false", section["aria-grabbed"]
    assert_event_count "sankey_preview_displayed", 2
  end

  test "Turbo snapshots clear preview graphs, floating tooltips, and unsubmitted feedback" do
    sign_in @user
    assert_selector "#cashflow-preview svg .sankey-link"
    install_posthog_fake
    find("#cashflow-preview svg text", text: "Sankey Shopping", match: :first).hover
    assert_selector ".chart-tooltip.ph-no-capture", text: "Sankey Shopping"
    within "#cashflow-preview" do
      click_button "Something looks wrong"
    end
    within "#cashflow-preview-feedback-dialog" do
      fill_in "What did not show correctly?", with: "Not submitted"
    end
    snapshot = page.evaluate_script(<<~JS)
      (() => {
        document.dispatchEvent(new Event('turbo:before-cache'));
        const copy = document.body.cloneNode(true);
        return {
          previewGraphs: copy.querySelectorAll('#cashflow-preview svg .sankey-link').length,
          tooltips: copy.querySelectorAll('.chart-tooltip.ph-no-capture').length,
          feedback: copy.querySelector('#cashflow-preview-feedback').value,
          legacyGraph: !!copy.querySelector('#cashflow-sankey-chart svg .sankey-link')
        };
      })()
    JS
    assert_equal({ "previewGraphs" => 0, "tooltips" => 0, "feedback" => "", "legacyGraph" => true }, snapshot)
    assert_event_count "survey sent", 0
    assert_event_count "survey dismissed", 1
  end

  test "self-hosted displays and feedback use only the separate project" do
    with_self_hosting do
      sign_in @user
      visit root_path(start_date: @month.iso8601, end_date: Date.current.iso8601)
      assert_selector "#cashflow-preview svg .sankey-link"
      install_posthog_fake
      page.execute_script(<<~JS)
        const shared = window.posthog;
        window.posthog = {
          __loaded: true,
          has_opted_out_capturing: () => false,
          capture: () => { throw new Error('Wrong analytics destination'); },
          getSurveys: () => { throw new Error('Wrong survey destination'); },
          sankeyFeedback: shared
        };
        document.dispatchEvent(new Event('posthog:ready'));
      JS
      find("#cashflow-preview").scroll_to(:center)
      assert_event_count "sankey_preview_displayed", 1
      within "#cashflow-preview" do
        click_button "Expand"
      end
      assert_event_count "sankey_preview_displayed", 2
      find("#cashflow-preview-expanded-dialog").find("button[data-action='DS--dialog#close']").click
      within "#cashflow-preview" do
        click_button "Something looks wrong"
      end
      fill_in "cashflow-preview-feedback", with: "The labels overlap"
      click_button "Send feedback"
      assert_event_count "survey sent", 1
      assert page.evaluate_script("window.sankeyEvents.some(e => e.event === 'survey sent' && e.properties.$survey_id === 'test-survey')")
      find("#cashflow-preview-feedback-dialog").find("button[data-action='DS--dialog#close']").click
      page.execute_script("document.querySelector('#cashflow-preview').setAttribute('data-sankey-preview-feedback-key-value', '')")
      within "#cashflow-preview" do
        click_button "Looks right"
      end
      assert_selector "#cashflow-preview-feedback-dialog[open] [role='status']", text: "Feedback isn't available right now"
      assert_event_count "survey shown", 1
      assert_event_count "survey sent", 1
    end
  end

  private
    def install_posthog_fake
      page.execute_script(<<~JS)
        window.sankeyEvents = [];
        window.posthog = {
          __loaded: true,
          has_opted_out_capturing: () => false,
          capture: (event, properties) => { window.sankeyEvents.push({event, properties}); return {}; },
          getSurveys: callback => callback([{
            id: 'test-survey', type: 'api', start_date: '2026-09-14', end_date: null,
            questions: [
              {id: 'feedback-id', type: 'open', question: 'What did not show correctly?', optional: true},
              {id: 'rating-id', type: 'single_choice', choices: ['Looks right', 'Something looks wrong']}
            ]
          }])
        };
        document.querySelector('#cashflow-preview').setAttribute('data-sankey-preview-survey-id-value', 'test-survey');
        document.querySelector('#cashflow-preview').setAttribute('data-sankey-preview-feedback-key-value', 'test-public-token');
        document.dispatchEvent(new Event('posthog:ready'));
      JS
    end

    def assert_event_count(event, count)
      assert_selector "body" do
        page.evaluate_script("window.sankeyEvents.filter(e => e.event === #{event.to_json}).length") == count
      end
    end
end
