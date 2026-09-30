require "application_system_test_case"

# Turbo caches a page as it was left, and Back restores that copy. A drawer
# fetched into the page came back with it: stray and non-modal if it was still
# open, opened again if it had been closed.
class DialogBackTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
    @transfer = transfers(:one)
    # The fixture's kinds predate the transfer kinds, and without them its row
    # opens the transaction drawer instead of the transfer's.
    @transfer.outflow_transaction.update!(kind: "cc_payment")
    @transfer.inflow_transaction.update!(kind: "funds_movement")
    @row_link = "a[data-turbo-frame='drawer'][href='#{transfer_path(@transfer)}']"
    @account = accounts(:depository)
  end

  test "going back from an account the transfer drawer linked to shows the list without the drawer" do
    visit transactions_url
    open_transfer_drawer
    within("dialog[open]") { click_on @account.name }
    assert_selector "main h2", text: @account.name

    page.go_back
    assert_selector "main h1", text: I18n.t("transactions.index.title")
    assert_no_selector "dialog[open]"
  end

  test "a drawer closed before leaving the list stays closed on Back" do
    visit transactions_url
    open_transfer_drawer
    page.send_keys(:escape)
    assert_no_selector "dialog[open]"

    leave_the_list_and_come_back
    assert_no_selector "dialog[open]"
  end

  # The modal frame is emptied as its dialog closes, however it closes. Escape
  # closes it natively, without the controller's close.
  test "a modal closed with Escape before leaving the list stays closed on Back" do
    visit transactions_url
    click_on I18n.t("transactions.index.new_transaction")
    assert_selector "turbo-frame#modal dialog[open]"
    page.send_keys(:escape)
    assert_no_selector "dialog[open]"

    leave_the_list_and_come_back
    assert_no_selector "dialog[open]"
  end

  # Visited directly, the drawer is the page, so Back has to bring it back.
  test "going back to a drawer visited directly restores it as a modal" do
    visit transfer_url(@transfer)
    within("dialog[open]") { click_on @account.name }
    assert_selector "main h2", text: @account.name

    page.go_back
    within("dialog:modal") { assert_link @account.name }
  end

  private
    # The row's name is cut to nothing beside its badges, so this clicks the
    # link the way the row's own click handler does.
    def open_transfer_drawer
      execute_script("arguments[0].click()", find(@row_link, visible: :all))
      within("dialog[open]") { assert_link @account.name }
    end

    def leave_the_list_and_come_back
      find("a[href='#{reports_path}']", match: :first).click
      assert_selector "h1", text: I18n.t("reports.index.title")

      page.go_back
      assert_selector "main h1", text: I18n.t("transactions.index.title")
    end
end
