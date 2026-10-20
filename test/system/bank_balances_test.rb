require "application_system_test_case"

class BankBalancesTest < ApplicationSystemTestCase
  test "bank observations stay readable on desktop and mobile without changing the account total" do
    account = accounts(:depository)
    account.update!(currency: "EUR", balance: 1500, cash_balance: 1500)
    item = EnableBankingItem.create!(family: account.family, name: "BPER", aspsp_name: "BPER Banca",
                                    country_code: "IT", application_id: "test", client_certificate: "test")
    provider = item.enable_banking_accounts.create!(name: "Checking", uid: "balance-display", currency: "EUR",
      balance_snapshot: Provider::BankBalanceSnapshot.build_enable_banking(
        balances: [
          { balance_type: "CLBD", balance_amount: { amount: "1500.00", currency: "EUR" }, reference_date: "2026-10-19" },
          { balance_type: "XPCD", balance_amount: { amount: "1250.00", currency: "EUR" }, reference_date: "2026-10-20" }
        ], fetched_at: Time.utc(2026, 10, 20, 16, 37), bank_name: "BPER Banca", country_code: "IT"
      ))
    AccountProvider.create!(account: account, provider: provider)
    sign_in users(:family_admin)

    [ [ 1400, "desktop" ], [ 390, "mobile" ] ].each do |width, label|
      page.current_window.resize_to(width, 1000)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: width, height: 1000, deviceScaleFactor: 1, mobile: width < 600)
      visit account_path(account)

      assert_text "Booked balance"
      assert_text "Available balance"
      assert_text "1,500.00"
      assert_text "1,250.00"
      assert_text "CLBD"
      assert_text "XPCD"
      assert_text "EUR"
      assert_equal 1500.to_d, account.reload.balance
      assert_equal width, page.evaluate_script("window.innerWidth")
      assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")

      if ENV["BALANCE_SCREENSHOTS"] == "1"
        page.save_screenshot(Rails.root.join("tmp/screenshots/bank-balances-#{label}.png"))
      end
    end
  ensure
    page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
  end
end
