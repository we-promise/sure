require "application_system_test_case"

class HoldingSecurityRemapTest < ApplicationSystemTestCase
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(show_sidebar: false, show_ai_sidebar: false)
    @account = accounts(:investment)
    @holding = holdings(:one)
  end

  # The remap form sits inside the holding drawer's turbo-frame. A plain
  # redirect on failure is followed inside that frame, which finds no
  # matching frame on the account page and shows "Content missing" instead
  # of the alert.
  test "a remap that fails shows its alert instead of an empty drawer" do
    old_security_id = @holding.security_id
    Balance::Materializer.any_instance.stubs(:materialize_balances).raises(StandardError, "forced test failure")

    Security.stubs(:providers).returns([ Object.new ])
    visit account_path(@account, tab: "holdings")
    find("a[href='#{holding_path(@holding)}']", match: :first).click
    find("button[aria-label='#{I18n.t("holdings.show.edit_security")}']").click
    Security.unstub(:providers)

    within "dialog" do
      form = find("form[action='#{remap_security_holding_path(@holding)}']", match: :first)
      # Pick a security without the provider search the combobox runs.
      page.execute_script(<<~JS, form)
        arguments[0].querySelector("input[type=hidden][name=security_id]").value = "MSFT|XNAS";
        arguments[0].noValidate = true;
      JS
      form.click_button I18n.t("holdings.show.remap_security")
    end

    assert_text I18n.t("holdings.remap_security.failed")
    assert_no_text "Content missing"
    assert_equal old_security_id, @holding.reload.security_id
  end
end
