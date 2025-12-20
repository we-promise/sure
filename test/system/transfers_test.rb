require "application_system_test_case"

class TransfersTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    visit transactions_url
  end

  test "can create a transfer" do
    checking_name = accounts(:depository).name
    savings_name = accounts(:credit_card).name
    transfer_date = Date.current

    click_on "New transaction"

    # Will navigate to different route in same modal
    click_on I18n.t("shared.transaction_tabs.transfer")
    assert_text I18n.t("transfers.new.title")

    select checking_name, from: I18n.t("transfers.form.from")
    select savings_name, from: I18n.t("transfers.form.to")
    fill_in "transfer[amount]", with: 500
    fill_in "transfer_date", with: transfer_date

    click_button I18n.t("transfers.form.submit")

    within "#entry-group-" + transfer_date.to_s do
      assert_text "Payment to"
    end
  end
end
