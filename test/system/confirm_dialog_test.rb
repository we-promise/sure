require "application_system_test_case"

# Confirmation bodies interpolate names that come from bank feeds, providers and
# other family members, so the dialog has to show them as text.
class ConfirmDialogTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    login_as @user
  end

  test "shows a provider merchant's name as text instead of rendering it" do
    name = %(<img src=x onerror="document.body.dataset.injected='yes'"> Coffee)
    merchant = ProviderMerchant.create!(name: name, source: "plaid")
    Transaction.joins(entry: :account).merge(@user.accessible_accounts).first.update!(merchant: merchant)

    visit family_merchants_path

    within "tr", text: "Coffee" do
      find("[data-DS--menu-target='button']").click
    end
    click_on I18n.t("family_merchants.provider_merchant.remove")

    within "#confirm-dialog" do
      assert_text I18n.t("family_merchants.provider_merchant.remove_confirm_body", name: name)
      assert_no_selector "img"
    end
    assert_nil page.evaluate_script("document.body.dataset.injected")
  end
end
