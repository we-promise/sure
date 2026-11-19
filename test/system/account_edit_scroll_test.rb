require "application_system_test_case"

# Editing an account from its page used to post the whole page and reload it,
# landing back at the top. Through Turbo, the save returns to the same page as
# a morphing refresh that keeps where the page was scrolled to.
class AccountEditScrollTest < ApplicationSystemTestCase
  include EntriesTestHelper

  setup do
    @account = accounts(:depository)
    30.times { |i| create_transaction(account: @account, name: "Entry #{i}", date: (i + 1).days.ago.to_date, amount: 10 + i) }
    sign_in users(:family_admin)
  end

  test "renaming an account from its page keeps the page where it was scrolled to" do
    page.driver.browser.manage.window.resize_to(1400, 900)
    visit account_path(@account)
    page.execute_script(%(window.notReloaded = true; document.getElementById("main").scrollTop = 600))
    assert_equal 600, main_scroll

    find("a[href='#{edit_account_path(@account)}']", visible: :all).execute_script("this.click()")
    within("dialog[open]") do
      find("input[name='account[name]']").set("Renamed account")
      click_on I18n.t("helpers.submit.update", model: "Account")
    end

    assert_selector "h2", text: "Renamed account"
    assert page.evaluate_script("window.notReloaded === true"), "the page was reloaded instead of refreshed"
    assert_in_delta 600, main_scroll, 5
  end

  test "an edit that fails shows its error in the modal" do
    visit account_path(@account)
    find("a[href='#{edit_account_path(@account)}']", visible: :all).execute_script("this.click()")
    within("dialog[open]") do
      find("input[name='account[name]']").set("")
      page.execute_script(%(document.querySelector("dialog[open] input[name='account[name]']").removeAttribute("required")))
      click_on I18n.t("helpers.submit.update", model: "Account")
    end

    assert_selector "dialog[open] input[name='account[name]']"
    assert_selector "dialog[open]", text: /can.t be blank/i
  end

  private
    def main_scroll
      page.evaluate_script(%(Math.round(document.getElementById("main").scrollTop)))
    end
end
