require "application_system_test_case"

class TradesTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    sign_in @user = users(:family_admin)

    @user.update!(show_sidebar: false, show_ai_sidebar: false)

    @account = accounts(:investment)

    # Disable provider to focus on form testing
    Security.stubs(:provider).returns(nil)
    Security.stubs(:providers).returns([])

    visit_account_portfolio
  end

  test "can create buy transaction" do
    shares_qty = 25

    open_new_trade_modal

    fill_in "Ticker symbol", with: "AAPL"
    fill_in "Date", with: Date.current
    fill_in "Quantity", with: shares_qty
    fill_in "model[price]", with: 214.23

    click_button "Add transaction"

    assert_text "Entry created"

    visit_trades

    within_trades do
      assert_text "Buy #{shares_qty}.0 shares of AAPL"
    end
  end

  test "can create sell transaction" do
    qty = 10
    aapl = @account.holdings.find { |h| h.security.ticker == "AAPL" }

    open_new_trade_modal

    select "Sell", from: "Type"
    assert_selector "turbo-frame#modal form[data-trade-type='sell']"

    fill_in "Ticker symbol", with: "AAPL"
    fill_in "Date", with: Date.current
    fill_in "Quantity", with: qty
    fill_in "model[price]", with: 215.33

    click_button "Add transaction"

    assert_text "Entry created"

    visit_trades

    within_trades do
      assert_text "Sell #{qty}.0 shares of AAPL"
    end
  end

  test "rejects negative price and fee on an existing trade" do
    entry = entries(:trade)
    trade = entry.trade
    original_price = trade.price
    original_fee = trade.fee

    visit trade_path(entry)

    # The money field is a text input (it accepts expressions), so the
    # min: 0 these fields request must be enforced by money_field_controller
    # instead of the browser. requestSubmit() from auto_submit_form runs
    # constraint validation, so an out-of-range value is never auto-saved.
    within "turbo-frame#drawer" do
      fill_in "Cost per Share", with: "-5"
      find_field("Cost per Share").send_keys(:tab)
      assert_equal "Enter an amount of at least 0.",
        find_field("Cost per Share").evaluate_script("this.validationMessage")

      fill_in "Transaction fee", with: "-10"
      find_field("Transaction fee").send_keys(:tab)
      assert_equal "Enter an amount of at least 0.",
        find_field("Transaction fee").evaluate_script("this.validationMessage")
    end

    # Give a (wrongly) triggered auto-submit time to land before checking.
    sleep 0.5
    trade.reload
    assert_equal original_price, trade.price
    assert_equal original_fee, trade.fee
  end

  test "still auto-saves an expression within bounds on an existing trade" do
    entry = entries(:trade)
    trade = entry.trade

    visit trade_path(entry)

    within "turbo-frame#drawer" do
      fill_in "Transaction fee", with: "1,50+1"
      find_field("Transaction fee").send_keys(:tab)
    end

    assert_eventually { trade.reload.fee.to_d == 2.5.to_d }
  end

  private
    def assert_eventually(timeout: Capybara.default_max_wait_time)
      deadline = Time.current + timeout
      until yield
        flunk "condition not met within #{timeout}s" if Time.current > deadline
        sleep 0.1
      end
    end

    def open_new_trade_modal
      click_on "New activity"
    end

    def within_trades(&block)
      within "#" + dom_id(@account, "entries"), &block
    end

    def visit_trades
      visit account_path(@account, tab: "activity")
    end

    def visit_account_portfolio
      visit account_path(@account, tab: "holdings")
    end
end
