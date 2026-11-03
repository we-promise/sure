require "application_system_test_case"

class EtoroDisplayModeTest < ApplicationSystemTestCase
  setup do
    sign_in users(:family_admin)
    @account = accounts(:investment)
    etoro_accounts(:main_account).ensure_account_provider!(@account)
  end

  test "the hint under the display mode describes the mode picked before the change is submitted" do
    visit accounts_path

    container = find("label", exact_text: I18n.t("etoro_items.display_mode.label", account: @account.name)).ancestor("[data-controller~=select]")
    assert_text hint(:holdings)

    container.find("button").click
    container.find("[role='listbox'] [role='option'][data-value='totals']", visible: true).click

    assert_text hint(:totals)
    assert_no_text hint(:holdings)
    assert_equal "holdings", etoro_accounts(:main_account).reload.display_mode, "nothing is saved until Change is pressed"
  end

  private

    def hint(mode)
      I18n.t("etoro_items.display_mode.hint.#{mode}")
    end
end
