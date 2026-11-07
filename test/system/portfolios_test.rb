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

  # A name that is clipped still sits in the DOM, so the assertion is on the
  # rendered box: nothing of the name hidden, and the table no wider than its
  # scroll region. With both sidebars closed the table fits its region, so an
  # overflow can only come from the name; the second name is too long for one
  # line and must wrap.
  test "a long security name shows in full without widening the holdings table" do
    @user.update_columns(show_sidebar: false, show_ai_sidebar: false)
    names = {
      "VTI" => "Vanguard Total Stock Market ETF",
      "VTIAX" => "Vanguard Total International Stock Index Fund Admiral Shares Accumulating Class Units Hedged To The Australian Dollar"
    }
    names.each do |ticker, name|
      Holding.create!(account: accounts(:investment), security: Security.create!(ticker: ticker, name: name),
                      date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD")
    end
    visit portfolio_path

    names.each do |ticker, name|
      shown = find("#portfolio-holdings tr[data-portfolio-holding='#{ticker}'] p", exact_text: name)
      assert page.evaluate_script("arguments[0].scrollWidth <= arguments[0].clientWidth", shown),
             "#{ticker}'s name is clipped"
    end
    region = find("#portfolio-holdings [role='region']")
    assert page.evaluate_script("arguments[0].scrollWidth <= arguments[0].clientWidth", region),
           "the holdings table overflows its scroll region"
  end
end
