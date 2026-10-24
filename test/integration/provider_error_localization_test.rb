require "test_helper"

class ProviderErrorLocalizationTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    Family.any_instance.stubs(:has_lunchflow_credentials?).returns(false)
    Provider::LunchflowAdapter.expects(:build_provider).never
  end

  test "unconfigured Lunch Flow redirects use explicit translations in every locale" do
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      expected = I18n.t("lunchflow_items.setup_accounts.no_api_key", locale: locale, fallback: false, raise: true)
      get select_accounts_lunchflow_items_path, params: { locale: locale }
      assert_redirected_to settings_providers_path
      assert_equal expected, flash[:alert]

      get select_existing_account_lunchflow_items_path, params: { locale: locale, account_id: accounts(:depository).id }
      assert_redirected_to settings_providers_path
      assert_equal expected, flash[:alert]
    end
  end

  test "missing Wise selection uses explicit translations without fetching accounts" do
    Provider::Wise.any_instance.expects(:get_balances).never
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      get select_existing_account_wise_items_path, params: { locale: locale, account_id: "missing-synthetic-account" }
      assert_redirected_to accounts_path
      assert_equal I18n.t("wise_items.link_existing_account.not_found", locale: locale, fallback: false, raise: true), flash[:alert]
    end
  end
end
