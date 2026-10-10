require "application_system_test_case"

class MonthlySpendingTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: { "preview_features_enabled" => true, "section_order" => %w[money_flow monthly_spending],
      "hidden_sections" => %w[insights_feed cashflow_sankey spending_trend outflows_donut investment_summary net_worth_chart balance_sheet] })
    @account = accounts(:depository)
    12.times do |offset|
      date = Date.current.beginning_of_month - offset.months
      create_transaction(account: @account, date: date, amount: 200 + offset * 25, category: categories(:food_and_drink))
      create_transaction(account: @account, date: date, amount: 90 + offset * 10)
    end
  end

  teardown do
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride") if @emulating_mobile
  end

  test "keyboard month selection and explicit empty account filters" do
    page.current_window.resize_to(1920, 1600)
    sign_in @user
    within "#monthly-spending-section" do
      assert_selector "[data-controller='DS--monthly-spending-chart']"
      bar = find("button[data-month='#{Date.current.beginning_of_month.iso8601}']")
      bar.send_keys(:enter)
      assert_selector "details[data-month][open]", count: 1
      click_on I18n.t("pages.dashboard.monthly_spending.filters")
      within find("legend", text: I18n.t("pages.dashboard.monthly_spending.accounts"), exact_text: true).ancestor("fieldset") do
        click_on I18n.t("ds.filter_checklist.none")
      end
      click_on I18n.t("pages.dashboard.monthly_spending.apply")
      assert_text I18n.t("pages.dashboard.monthly_spending.empty_selection")
      assert_no_selector "[data-controller='DS--monthly-spending-chart']"
      click_on I18n.t("pages.dashboard.monthly_spending.reset")
    end
    assert_no_selector "#monthly-spending-section input[type='search']", visible: true
    assert_selector "#monthly-spending-section [data-controller='DS--monthly-spending-chart']"
    FileUtils.mkdir_p(Rails.root.join("tmp/screenshots"))
    section = find("section[data-section-key='monthly_spending']")
    page.driver.browser.execute_script("arguments[0].scrollIntoView({block: 'start', inline: 'nearest'})", section.native)
    section.native.save_screenshot(Rails.root.join("tmp/screenshots/monthly-spending-desktop.png").to_s)
  end

  test "mobile card scrolls within the page and filter search preserves selections" do
    @emulating_mobile = true
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: true)
    sign_in @user
    within "#monthly-spending-section" do
      assert_selector "[data-controller='DS--monthly-spending-chart']"
      assert_equal 390, page.evaluate_script("window.innerWidth")
      assert page.evaluate_script("document.documentElement.scrollWidth <= document.documentElement.clientWidth")
      scroller = find("[data-DS--monthly-spending-chart-target='scroller']")
      assert_operator scroller.native.property("scrollWidth"), :>, scroller.native.property("clientWidth")
      click_on I18n.t("pages.dashboard.monthly_spending.filters")
      within find("legend", text: I18n.t("pages.dashboard.monthly_spending.accounts"), exact_text: true).ancestor("fieldset") do
        find("input[type='search']").set("no matching account")
        assert_text I18n.t("ds.filter_checklist.no_results")
      end
      click_on I18n.t("pages.dashboard.monthly_spending.apply")
    end
    assert_no_selector "#monthly-spending-section input[type='search']", visible: true
    assert_selector "#monthly-spending-section [data-controller='DS--monthly-spending-chart']"
    FileUtils.mkdir_p(Rails.root.join("tmp/screenshots"))
    page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 1400, deviceScaleFactor: 1, mobile: true)
    section = find("section[data-section-key='monthly_spending']")
    page.driver.browser.execute_script("arguments[0].scrollIntoView({block: 'start', inline: 'nearest'})", section.native)
    section.native.save_screenshot(Rails.root.join("tmp/screenshots/monthly-spending-mobile.png").to_s)
  end

  test "month picker prevents invalid ranges without overwriting the draft" do
    page.current_window.resize_to(1280, 1000)
    sign_in @user
    within "#monthly-spending-section" do
      assert_selector "[data-monthly-spending-total]", count: 12
      click_on I18n.t("pages.dashboard.monthly_spending.filters")
      select Date.current.year.to_s, from: "monthly_spending_from_year"
      select I18n.t("date.month_names")[Date.current.month], from: "monthly_spending_from_month"
      select (Date.current.year - 1).to_s, from: "monthly_spending_to_year"
      assert_button I18n.t("pages.dashboard.monthly_spending.apply"), disabled: true
      assert_text I18n.t("pages.dashboard.monthly_spending.invalid_period")
      assert_equal Date.current.month.to_s, find("#monthly_spending_from_month").value
      select Date.current.year.to_s, from: "monthly_spending_to_year"
      assert_button I18n.t("pages.dashboard.monthly_spending.apply"), disabled: false
      click_on I18n.t("pages.dashboard.monthly_spending.apply")
    end
    assert_no_selector "#monthly-spending-section select", visible: true
    assert_selector "[data-monthly-spending-total]", count: 1
    visit root_path
    assert_selector "[data-monthly-spending-total]", count: 1
    assert_text I18n.t("pages.dashboard.monthly_spending.share").upcase
  end

  test "period presets save through the menu and survive a new dashboard visit" do
    sign_in @user
    within "#monthly-spending-section" do
      click_on I18n.t("pages.dashboard.monthly_spending.period")
      click_on I18n.t("pages.dashboard.monthly_spending.this_year")
    end
    assert_selector "[data-monthly-spending-total]", count: Date.current.month
    visit root_path
    assert_selector "[data-monthly-spending-total]", count: Date.current.month
  end
end
