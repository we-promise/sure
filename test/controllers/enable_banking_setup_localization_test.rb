require "test_helper"

class EnableBankingSetupLocalizationTest < ActionDispatch::IntegrationTest
  TYPE_KEYS = %w[skip depository credit_card investment loan other_asset].freeze
  TYPE_VALUES = %w[skip Depository CreditCard Investment Loan OtherAsset].freeze
  SUBTYPE_CLASSES = [ Depository, Investment, Loan ].freeze
  SETUP_SCOPE = "lunchflow_items.setup_accounts".freeze
  PLACEHOLDER_SCOPE = "lunchflow_items.subtype_select.placeholder".freeze

  setup do
    @family = families(:dylan_family)
    @family.update!(auto_sync_on_login: false)
    sign_in users(:family_admin)
    @item = @family.enable_banking_items.create!(
      name: "Synthetic setup connection",
      country_code: "DE",
      application_id: "synthetic-app-id",
      client_certificate: "synthetic-test-placeholder-not-a-real-certificate"
    )
    @provider_account = @item.enable_banking_accounts.create!(
      name: "Synthetic account name stays unchanged",
      uid: "synthetic-setup-account",
      currency: "EUR",
      account_type: "CACC"
    )
    EnableBankingItem.any_instance.expects(:enable_banking_provider).never
    EnableBankingItem.any_instance.expects(:sync_later).never
  end

  %w[zh-CN fr en].each do |locale|
    test "#{locale} setup localizes account choices while preserving values order and suggestions" do
      get setup_accounts_enable_banking_item_url(@item, locale: locale)

      assert_response :success
      assert_includes response.parsed_body.text, @provider_account.name
      selector = "select[name='account_types[#{@provider_account.id}]'] option"
      options = response.parsed_body.css(selector)
      assert_equal TYPE_VALUES, options.map { |option| option["value"] }
      assert_equal TYPE_KEYS.map { |key| translation("#{SETUP_SCOPE}.account_types.#{key}", locale) }, options.map(&:text)
      assert_select "#{selector}[selected]", count: 1
      assert_select "#{selector}[value='Depository'][selected]", count: 1

      SUBTYPE_CLASSES.each do |accountable|
        container = response.parsed_body.at_css(".subtype-select[data-type='#{accountable.name}']")
        assert container, "Missing #{accountable.name} subtype controls"
        subtype_options = container.css("select option")
        assert_equal [ "", *accountable::SUBTYPES.keys ], subtype_options.map { |option| option["value"] }
        prompt = accountable == Depository ? "subtype" : "type"
        assert_equal translation("#{PLACEHOLDER_SCOPE}.#{prompt}", locale), subtype_options.first.text
        assert_equal accountable::SUBTYPES.keys.map { |key| translation("#{accountable.name.underscore.pluralize}.subtypes.#{key}.long", locale) }, subtype_options.drop(1).map(&:text)
        assert_equal translation("#{SETUP_SCOPE}.subtype_labels.#{accountable.name.underscore}", locale), container.at_css("label").text
      end

      assert_select ".subtype-select[data-type='Depository'] option[value='checking'][selected]", count: 1
      %w[CreditCard OtherAsset].each do |type|
        container = response.parsed_body.at_css(".subtype-select[data-type='#{type}']")
        assert_empty container.css("select")
        assert_equal translation("#{SETUP_SCOPE}.subtype_messages.#{type.underscore}", locale), container.at_css("p").text.strip
      end
    end
  end

  test "all supported locales explicitly provide the reused setup copy and every model subtype" do
    keys = TYPE_KEYS.map { |key| "#{SETUP_SCOPE}.account_types.#{key}" }
    keys += %w[depository investment loan].map { |key| "#{SETUP_SCOPE}.subtype_labels.#{key}" }
    keys += %w[credit_card other_asset].map { |key| "#{SETUP_SCOPE}.subtype_messages.#{key}" }
    keys += %w[subtype type].map { |key| "#{PLACEHOLDER_SCOPE}.#{key}" }
    SUBTYPE_CLASSES.each do |accountable|
      keys += accountable::SUBTYPES.keys.map { |key| "#{accountable.name.underscore.pluralize}.subtypes.#{key}.long" }
    end

    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      keys.each do |key|
        assert I18n.exists?(key, locale, fallback: false), "#{locale} missing #{key}"
        assert translation(key, locale).present?, "#{locale} empty #{key}"
      end
    end
  end

  private
    def translation(key, locale)
      I18n.t(key, locale: locale, fallback: false, raise: true)
    end
end
