require "test_helper"

class InterfaceGapLocalizationTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
  end

  test "provider setup pages show translated historical import and the complete savings notice" do
    binance = @user.family.binance_items.create!(
      name: "Synthetic Binance", api_key: "synthetic-unused-key", api_secret: "synthetic-unused-secret"
    )
    banking = @user.family.enable_banking_items.create!(
      name: "Synthetic banking", country_code: "FR", application_id: "synthetic-unused-id",
      client_certificate: "synthetic-unused-certificate"
    )

    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      get setup_accounts_binance_item_path(binance), params: { locale: locale }
      assert_response :success
      assert_select "p", text: translation("binance_items.setup_accounts.historical_import", locale)

      get setup_accounts_enable_banking_item_path(banking), params: { locale: locale }
      assert_response :success
      notice = translation("enable_banking_items.setup_accounts.psd2_savings_notice", locale)
      assert_select "p", text: notice
      %w[Livret PEL LEP LDDS].each { |name| assert_includes notice, name }
      assert_select ".translation_missing", count: 0
    end
  end

  test "report period and transaction type controls have translated accessible names" do
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      get reports_path, params: { locale: locale }
      assert_response :success
      assert_select "[role='group'][aria-label=?]", translation("reports.index.period_aria", locale)

      get new_transaction_path, params: { locale: locale }
      assert_response :success
      assert_select "[role='group'][aria-label=?]", translation("shared.transaction_tabs.aria", locale)
      assert_select ".translation_missing", count: 0
    end
  end

  test "blank balance submissions render translated amount and submit labels without adding entries" do
    assert_no_difference [ "Entry.count", "Valuation.count" ] do
      LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
        post confirm_create_valuations_path, params: {
          locale: locale,
          entry: { amount: "", date: Date.current.to_s, account_id: accounts(:investment).id }
        }
        assert_response :unprocessable_entity
        assert_select "label[for='entry_amount']", text: /\A\s*#{Regexp.escape(translation("valuations.form.amount", locale))}\s*\*\s*\z/
        assert_select "button[type='submit']", text: translation("valuations.form.submit", locale)
        assert_select ".translation_missing", count: 0
      end
    end
  end

  private
    def translation(key, locale)
      I18n.t(key, locale: locale, fallback: false, raise: true).tap do |value|
        assert value.is_a?(String) && value.present?, "Expected explicit #{locale} translation for #{key}"
      end
    end
end
