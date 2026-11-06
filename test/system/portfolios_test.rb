require "application_system_test_case"

class PortfoliosTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    sign_in @user
  end

  # The collapse state is saved with the page's CSRF token and nothing is
  # saved without one, and the test environment renders none unless forgery
  # protection is on.
  test "collapsing a section saves it under the portfolio keys, not the Reports ones" do
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    visit portfolio_path
    record_saved_section_order

    find("section[data-section-key='accounts'] summary").click

    assert_selector "section[data-section-key='accounts'] details:not([open])"
    assert_selector "html[data-order-saved='200']"
    assert_equal true, @user.reload.preferences.dig("portfolio_collapsed_sections", "accounts")
    assert_nil @user.preferences["reports_collapsed_sections"]
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  test "a holding's toggle reveals and hides its per-account positions" do
    visit portfolio_path

    toggle = find("#portfolio-holdings tr[data-portfolio-holding='AAPL'] button[aria-controls]")
    detail_id = toggle["aria-controls"]
    assert_no_selector "##{detail_id}"

    toggle.click
    assert_selector "##{detail_id} [data-portfolio-positions='AAPL'] a[href^='/holdings/']"
    assert_equal "true", toggle["aria-expanded"]

    toggle.click
    assert_no_selector "##{detail_id}"
    assert_equal "false", toggle["aria-expanded"]
  end

  test "a holdings column header sorts the table and flips on a second click" do
    Holding.create!(account: accounts(:investment), security: Security.create!(ticker: "ZZZ", name: "Zeta"),
                    date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")
    visit portfolio_path

    find("#portfolio-holdings th a[href*='sort=name']").click
    assert_selector "#portfolio-holdings th[aria-sort='ascending'] a[href*='sort=name']"
    assert_equal %w[AAPL ZZZ], all("#portfolio-holdings tr[data-portfolio-holding]").map { |row| row["data-portfolio-holding"] }

    find("#portfolio-holdings th a[href*='sort=name']").click
    assert_selector "#portfolio-holdings th[aria-sort='descending'] a[href*='sort=name']"
    assert_equal %w[ZZZ AAPL], all("#portfolio-holdings tr[data-portfolio-holding]").map { |row| row["data-portfolio-holding"] }
  end
end
