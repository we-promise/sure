require "application_system_test_case"

class ConfirmDialogTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.update!(locale: nil, show_sidebar: false, show_ai_sidebar: false)
    @account = accounts(:investment)
    @holding = holdings(:one)
    @holding.update!(cost_basis: 50, cost_basis_source: "manual", cost_basis_locked: true)

    Security.stubs(:provider).returns(nil)
    Security.stubs(:providers).returns([])

    sign_in @user
    @user.update!(locale: "de")
  end

  test "German server defaults cover boolean confirmation payloads without submitting" do
    open_holding

    click_button "Löschen"

    within_confirm_dialog do
      assert_text "Bist du sicher?"
      assert_text "Das lässt sich nicht rückgängig machen."
      assert_button "Bestätigen"
      cancel_confirmation
    end

    assert Holding.exists?(@holding.id), "cancelling the boolean delete confirmation submitted the destructive action"
  end

  test "German server defaults complete partial confirmation payloads without submitting" do
    open_holding

    title = I18n.t("holdings.show.unlock_confirm_title", locale: :de)
    body = I18n.t("holdings.show.unlock_confirm_body", locale: :de)
    delete_confirmation = find("turbo-frame#drawer [data-turbo-confirm='true']", visible: :all)
    page.execute_script(
      "arguments[0].setAttribute('data-turbo-confirm', arguments[1])",
      delete_confirmation,
      {
        title: title,
        body: body
      }.to_json
    )
    click_button "Löschen"

    within_confirm_dialog do
      assert_text title
      assert_text body
      assert_button "Bestätigen"
      cancel_confirmation
    end

    assert Holding.exists?(@holding.id), "cancelling the incomplete confirmation payload submitted the destructive action"
  end

  test "English server defaults remain unchanged for boolean confirmation payloads" do
    @user.update!(locale: "en")

    open_holding
    click_button "Delete"

    within_confirm_dialog do
      assert_text "Are you sure?"
      assert_text "This action cannot be undone."
      assert_button "Confirm"
      cancel_confirmation
    end

    assert Holding.exists?(@holding.id), "cancelling the English delete confirmation submitted the destructive action"
  end

  private
    def open_holding
      visit account_path(@account, tab: "holdings")
      click_link @holding.name, href: holding_path(@holding)
      assert_selector "turbo-frame#drawer", visible: true
    end

    def within_confirm_dialog(&block)
      assert_selector "#confirm-dialog", visible: true
      within "#confirm-dialog", &block
      assert_no_selector "#confirm-dialog", visible: true
    end

    def cancel_confirmation
      find("button[value='cancel']").click
    end
end
