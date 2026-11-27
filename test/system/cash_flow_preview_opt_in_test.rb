require "application_system_test_case"

class CashFlowPreviewOptInTest < ApplicationSystemTestCase
  setup do
    @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge(
      "preview_features_enabled" => true,
      "cashflow_preview_enabled" => false
    ))
  end

  test "a preview user turns the cashflow comparison on and off from the dashboard" do
    sign_in @user
    visit root_path

    assert_no_selector "#cashflow-preview"
    opt_in = find("label[for='cashflow_preview_enabled']", text: I18n.t("pages.dashboard.cashflow_preview.opt_in_title"))
    opt_in.click

    assert_selector "#cashflow-preview"
    assert @user.reload.cashflow_preview_enabled?

    find("label[for='cashflow_preview_enabled']", text: I18n.t("pages.dashboard.cashflow_preview.opt_in_title")).click

    assert_no_selector "#cashflow-preview"
    assert_not @user.reload.cashflow_preview_enabled?
  end
end
