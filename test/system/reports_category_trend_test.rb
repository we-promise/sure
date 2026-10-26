require "application_system_test_case"

class ReportsCategoryTrendTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
    page.driver.browser.manage.window.resize_to(1400, 900)
    visit reports_path(
      period_type: :custom,
      start_date: 2.years.ago.beginning_of_year.to_date,
      end_date: Date.current.end_of_month.to_date
    )
  end

  test "a selected category draws a trend that survives a period change" do
    click_button I18n.t("reports.trends.category_trend.select")

    find("label", text: categories(:food_and_drink).display_name).click
    click_button I18n.t("reports.trends.category_trend.apply")

    assert_selector "[data-controller='multi-series-chart'] svg"
    assert_selector "h3", text: I18n.t("reports.trends.category_trend.title")
    assert_current_path(/trend_category_ids/)

    click_link I18n.t("reports.trends.category_trend.year")

    assert_current_path(/trend_granularity=year/)
    assert_selector "[data-controller='multi-series-chart'] svg"
  end

  test "the category trend controls work at a mobile width" do
    page.driver.browser.manage.window.resize_to(390, 844)
    visit reports_path(
      period_type: :custom,
      start_date: 2.years.ago.beginning_of_year.to_date,
      end_date: Date.current.end_of_month.to_date
    )

    within "section[data-section-key='trends_insights']" do
      click_button I18n.t("reports.trends.category_trend.select")
      find("label", text: categories(:food_and_drink).display_name).click
      click_button I18n.t("reports.trends.category_trend.apply")

      assert_selector "[data-controller='multi-series-chart'] svg"
    end

    assert_current_path(/trend_category_ids/)
  end

  test "a monthly trend spanning two years labels both years" do
    visit reports_path(
      period_type: :custom,
      start_date: (Date.current - 12.months).beginning_of_month.to_date,
      end_date: Date.current.end_of_month.to_date
    )

    click_button I18n.t("reports.trends.category_trend.select")
    find("label", text: categories(:food_and_drink).display_name).click
    click_button I18n.t("reports.trends.category_trend.apply")

    within "[data-controller='multi-series-chart']" do
      assert_selector "svg text", text: Date.current.year.to_s
      assert_selector "svg text", text: (Date.current.year - 1).to_s
    end
  end

  test "year view on a one-year period shows a dot per category" do
    visit reports_path(period_type: :ytd)

    click_button I18n.t("reports.trends.category_trend.select")
    find("label", text: categories(:food_and_drink).display_name).click
    click_button I18n.t("reports.trends.category_trend.apply")

    assert_selector "[data-controller='multi-series-chart'] svg", minimum: 1
    assert_current_path(/trend_category_ids/)
    click_link I18n.t("reports.trends.category_trend.year")

    assert_current_path(/trend_granularity=year/)
    assert_selector "[data-controller='multi-series-chart'] svg circle", minimum: 1
  end
end
