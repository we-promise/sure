require "application_system_test_case"

class AccountBulkReconciliationTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    ensure_tailwind_build
    sign_in @user = users(:family_admin)
    @user.family.update!(manual_reconciliation: true)
    @account = @user.family.accounts.create!(
      name: "[system test] Bulk reconciliation",
      balance: 100,
      currency: "USD",
      accountable: Depository.new
    )
    @entries = [
      create_transaction(account: @account, name: "First", amount: 10),
      create_transaction(account: @account, name: "Second", amount: 20)
    ]
  end

  test "reconciles every transaction from the account menu" do
    visit account_url(@account, tab: "activity")

    open_account_menu
    click_on I18n.t("accounts.show.menu.reconcile_all.reconciled")
    confirm_dialog

    assert_text I18n.t(
      "accounts.reconcile_all.success",
      count: @entries.size,
      status: I18n.t("transactions.reconcile.statuses.reconciled")
    )

    @entries.each do |entry|
      assert_equal "reconciled", entry.reload.reconciled_status
      assert_selector "##{dom_id(entry)} a[aria-label='#{I18n.t("transactions.reconcile.statuses.reconciled")}']"
    end
  end

  test "marking all unreconciled resets every transaction" do
    @entries.each { |entry| entry.update!(reconciled_status: "reconciled") }
    visit account_url(@account, tab: "activity")

    open_account_menu
    click_on I18n.t("accounts.show.menu.reconcile_all.unreconciled")
    confirm_dialog

    @entries.each do |entry|
      assert_equal "unreconciled", entry.reload.reconciled_status
      assert_selector "##{dom_id(entry)} a[aria-label='#{I18n.t("transactions.reconcile.statuses.unreconciled")}']"
    end
  end

  private
    # The account page morph-refreshes shortly after load. Retry a detached
    # node instead of racing the broadcast.
    def open_account_menu
      3.times do
        within_testid("account-menu") do
          find("button").click unless has_selector?("[role='menu']", visible: true, wait: 0)
        end
        return if has_selector?("[role='menu']", visible: true, wait: 2)
      rescue Selenium::WebDriver::Error::WebDriverError => e
        raise unless e.message.match?(/does not belong to the document|stale element reference/i)
      end

      assert_selector "[role='menu']", visible: true
    end

    def confirm_dialog
      within("#confirm-dialog") do
        find("button[value='confirm']:not([hidden])").click
      end
    end
end
