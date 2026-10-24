require "test_helper"

class ProviderSetupLocalizationTest < ActionDispatch::IntegrationTest
  SETUP_SCOPE = "lunchflow_items.setup_accounts".freeze
  PLACEHOLDER_SCOPE = "lunchflow_items.subtype_select.placeholder".freeze
  CRYPTO_MESSAGE_KEY = "provider_account_setup.crypto_holdings_message".freeze
  SUBTYPE_CLASSES = [ Depository, Investment, Loan ].freeze

  setup do
    @family = families(:dylan_family)
    @family.update!(auto_sync_on_login: false)
    sign_in users(:family_admin)

    # Synthetic test records only. These inert placeholders cannot connect to any provider.
    @simplefin_item = @family.simplefin_items.create!(
      name: "Synthetic SimpleFIN connection",
      access_url: "https://example.invalid/synthetic-localization"
    )
    @simplefin_account = @simplefin_item.simplefin_accounts.create!(
      name: "Synthetic Checking name stays unchanged",
      account_id: "synthetic-simplefin-account",
      currency: "USD", current_balance: 100, account_type: "depository"
    )
    @sophtron_item = @family.sophtron_items.create!(
      name: "Synthetic Sophtron connection",
      user_id: "synthetic-localization-user",
      access_key: "synthetic-test-placeholder-not-a-real-key"
    )
    @sophtron_account = @sophtron_item.sophtron_accounts.create!(
      name: "Synthetic Checking name stays unchanged",
      account_id: "synthetic-sophtron-account", currency: "USD", balance: 100
    )

    @mercury_item = mercury_items(:one)
    @mercury_account = mercury_accounts(:checking_account)
    MercuryItem.any_instance.expects(:mercury_provider).never
    MercuryItem.any_instance.expects(:sync_later).never

    SimplefinItem.any_instance.expects(:simplefin_provider).never
    SimplefinItem.any_instance.expects(:sync_later).never
    SophtronItem.any_instance.expects(:sophtron_provider).never
    SophtronItem.any_instance.expects(:fetch_remote_accounts).never
    SophtronItem.any_instance.expects(:sync_later).never
  end

  %w[zh-CN pt-PT en].each do |locale|
    test "#{locale} SimpleFIN setup localizes choices without changing values order or inference" do
      get setup_accounts_simplefin_item_url(@simplefin_item, locale: locale)

      assert_response :success
      assert_includes response.parsed_body.text, @simplefin_account.name
      options = response.parsed_body.css("select[name='account_types[#{@simplefin_account.id}]'] option")
      assert_equal %w[skip Depository CreditCard Investment Crypto Loan OtherAsset], options.map { |option| option["value"] }
      expected_labels = %w[skip depository credit_card investment].map { |key| translation("#{SETUP_SCOPE}.account_types.#{key}", locale) }
      expected_labels << translation("snaptrade_items.setup_accounts.account_types.crypto", locale)
      expected_labels += %w[loan other_asset].map { |key| translation("#{SETUP_SCOPE}.account_types.#{key}", locale) }
      assert_equal expected_labels, options.map(&:text)
      assert_equal [ "Depository" ], options.select { |option| option["selected"] }.map { |option| option["value"] }

      assert_subtype_controls(locale)
      warning = response.parsed_body.at_css(".subtype-select[data-type='Investment'] [class*='text-warning'] span")
      assert_equal translation("#{PLACEHOLDER_SCOPE}.type", locale), warning&.text
      assert_select ".subtype-select[data-type='Depository'][data-needs-attention='false']"
      assert_select ".subtype-select[data-type='Investment'][data-needs-attention='true']"
    end

    test "#{locale} Sophtron setup localizes choices without changing values order or inference" do
      get setup_accounts_sophtron_item_url(@sophtron_item, locale: locale)

      assert_response :success
      assert_includes response.parsed_body.text, @sophtron_account.name
      options = response.parsed_body.css("select[name='account_types[#{@sophtron_account.id}]'] option")
      assert_equal %w[skip Depository CreditCard Investment Loan], options.map { |option| option["value"] }
      keys = %w[skip depository credit_card investment loan]
      assert_equal keys.map { |key| translation("sophtron_items.setup_accounts.account_types.#{key}", locale) }, options.map(&:text)
      assert_equal [ "skip" ], options.select { |option| option["selected"] }.map { |option| option["value"] }
      assert_subtype_controls(locale)
      assert_select "title", text: /#{Regexp.escape(translation('sophtron_items.setup_accounts.title', locale))}/
    end
  end

  %w[zh-CN pt-PT en].each do |locale|
    test "#{locale} Mercury setup localizes title and placeholder without changing choices" do
      get setup_accounts_mercury_item_url(@mercury_item, locale: locale)

      assert_response :success
      assert_includes response.parsed_body.text, @mercury_account.name
      account_options = response.parsed_body.css("select[name='account_types[#{@mercury_account.id}]'] option")
      assert_equal %w[skip Depository], account_options.map { |option| option["value"] }
      assert_equal [ "skip" ], account_options.select { |option| option["selected"] }.map { |option| option["value"] }
      subtype_options = response.parsed_body.css(".subtype-select[data-type='Depository'] select option")
      assert_equal [ "", *Depository::SUBTYPES.keys ], subtype_options.map { |option| option["value"] }
      assert_equal translation("#{PLACEHOLDER_SCOPE}.subtype", locale), subtype_options.first.text
      assert_equal translation("depositories.subtypes.cash.long", locale), subtype_options.find { |option| option["value"] == "cash" }.text
      assert_equal [ "checking" ], subtype_options.select { |option| option["selected"] }.map { |option| option["value"] }
      assert_select "title", text: /#{Regexp.escape(translation('mercury_items.setup_accounts.title', locale))}/
    end
  end

  test "every supported locale explicitly provides the reused choices prompts and crypto guidance" do
    keys = %w[skip depository credit_card investment loan other_asset].map { |key| "#{SETUP_SCOPE}.account_types.#{key}" }
    keys += %w[depository investment loan].map { |key| "sophtron_items.setup_accounts.subtype_labels.#{key}" }
    keys += %w[credit_card other_asset].map { |key| "sophtron_items.setup_accounts.subtype_messages.#{key}" }
    keys += %w[subtype type].map { |key| "#{PLACEHOLDER_SCOPE}.#{key}" }
    keys += [ CRYPTO_MESSAGE_KEY, "snaptrade_items.setup_accounts.account_types.crypto" ]

    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      keys.each do |key|
        assert I18n.exists?(key, locale, fallback: false), "#{locale} missing #{key}"
        assert translation(key, locale).present?, "#{locale} empty #{key}"
      end
    end
  end

  private
    def assert_subtype_controls(locale)
      SUBTYPE_CLASSES.each do |accountable|
        container = response.parsed_body.at_css(".subtype-select[data-type='#{accountable.name}']")
        assert container, "Missing #{accountable.name} controls"
        options = container.css("select option")
        assert_equal [ "", *accountable::SUBTYPES.keys ], options.map { |option| option["value"] }
        prompt = accountable == Depository ? "subtype" : "type"
        assert_equal translation("#{PLACEHOLDER_SCOPE}.#{prompt}", locale), options.first.text
        expected_labels = accountable::SUBTYPES.keys.map do |key|
          translation("#{accountable.name.underscore.pluralize}.subtypes.#{key}.long", locale)
        end
        assert_equal expected_labels, options.drop(1).map(&:text)
        assert_equal translation("sophtron_items.setup_accounts.subtype_labels.#{accountable.name.underscore}", locale), container.at_css("label").text
        expected_selection = accountable == Depository ? "checking" : ""
        assert_equal [ expected_selection ], options.select { |option| option["selected"] }.map { |option| option["value"] }
      end

      %w[CreditCard Crypto OtherAsset].each do |type|
        container = response.parsed_body.at_css(".subtype-select[data-type='#{type}']")
        assert_empty container.css("select")
        key = type == "Crypto" ? CRYPTO_MESSAGE_KEY : "sophtron_items.setup_accounts.subtype_messages.#{type.underscore}"
        assert_equal translation(key, locale), container.at_css("p").text.strip
      end
    end

    def translation(key, locale)
      I18n.t(key, locale: locale, fallback: false, raise: true)
    end
end
