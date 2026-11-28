require "application_system_test_case"

# The provider kit's setup dialog, through Brex: choosing an account type
# shows that type's subtype dropdown, and the choices are submitted under the
# names the setup flow reads.
class ProviderAccountSetupTest < ApplicationSystemTestCase
  setup do
    @item = brex_items(:one)
    @brex_account = brex_accounts(:checking_account)
    BrexItem::AccountFlow.any_instance.stubs(:import_accounts_with_user_facing_error).returns(nil)
    sign_in users(:family_admin)
  end

  test "choosing an account type shows its subtype and sets up the account with both" do
    visit setup_accounts_brex_item_path(@item)

    depository_subtype = %(.subtype-select[data-type="Depository"])
    credit_card_subtype = %(.subtype-select[data-type="CreditCard"])
    assert_selector depository_subtype, visible: true
    assert_selector credit_card_subtype, visible: false

    choose_option "account_types_#{@brex_account.id}", "Credit Card"
    assert_selector credit_card_subtype, visible: true
    assert_selector depository_subtype, visible: false

    choose_option "account_types_#{@brex_account.id}", "Checking or Savings Account"
    assert_selector depository_subtype, visible: true
    choose_option "account_subtypes_#{@brex_account.id}", "Savings"

    assert_difference -> { @item.family.accounts.count }, 1 do
      click_on I18n.t("brex_items.setup_accounts.create_accounts")
      assert_current_path accounts_path
    end

    account = @brex_account.reload.account
    assert_equal "Depository", account.accountable_type
    assert_equal "savings", account.subtype
  end

  private
    def choose_option(field_id, label)
      find("##{field_id}_trigger").click
      find("##{field_id}_trigger").ancestor("[data-controller~='select']").find("[role='option']", text: label, exact_text: true).click
    end
end
