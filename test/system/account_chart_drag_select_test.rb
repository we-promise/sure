require "application_system_test_case"

class AccountChartDragSelectTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @account = accounts(:depository)
  end

  test "dragging across the balance chart navigates to the dragged date range" do
    sign_in @user

    visit account_url(@account)
    assert_text @account.name

    drag_across find("#lineChart .drag-select-brush .overlay", visible: :all)

    assert_current_path(%r{/accounts/#{@account.id}\?.*start_date=.*end_date=})
  end

  test "a dragged range filters the activity feed until a preset period replaces it" do
    inside = create_transaction(account: @account, name: "Inside the range", date: 15.days.ago.to_date)
    outside = create_transaction(account: @account, name: "Before the range", date: 60.days.ago.to_date)

    sign_in @user
    visit account_url(@account, period: "last_30_days", q: { search: "range" })
    assert_selector "##{dom_id(outside)}"

    drag_across find("#lineChart .drag-select-brush .overlay", visible: :all)

    assert_current_path(/q%5Bstart_date%5D=/)
    query = Rack::Utils.parse_nested_query(URI.parse(current_url).query)
    assert_equal query["start_date"], query.dig("q", "start_date")
    assert_equal query["end_date"], query.dig("q", "end_date")
    assert_equal "range", query.dig("q", "search")

    assert_selector "##{dom_id(inside)}"
    assert_no_selector "##{dom_id(outside)}"
    within "#account-activity-filters" do
      assert_selector "li", text: I18n.t("transactions.searches.filters.badge.on_or_after", date: query["start_date"])
      assert_selector "li", text: I18n.t("transactions.searches.filters.badge.on_or_before", date: query["end_date"])
    end

    find("button[aria-label^='#{I18n.t("UI.period_picker.aria_label", period: "")}']").click
    wait_for_turbo_load { click_link "90D" }

    assert_selector "button[aria-label='#{I18n.t("UI.period_picker.aria_label", period: "90D")}']"
    assert_selector "##{dom_id(outside)}"
    assert_no_selector "#account-activity-filters li", text: query["start_date"]
    assert_selector "#account-activity-filters li", text: "range"
    assert_no_current_path(/start_date/)
  end

  private
    # A pick renders its frame, then Turbo promotes it to a page visit that
    # pushes the new URL; wait for that visit before reading the URL.
    def wait_for_turbo_load
      execute_script("document.addEventListener('turbo:load', () => document.documentElement.dataset.turboLoaded = '', { once: true })")
      yield
      assert_selector "html[data-turbo-loaded]", visible: :all
      execute_script("delete document.documentElement.dataset.turboLoaded")
    end
end
