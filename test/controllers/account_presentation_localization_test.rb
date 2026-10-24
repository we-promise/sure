require "test_helper"

class AccountPresentationLocalizationTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @user.family.update!(auto_sync_on_login: false)
    sign_in @user
    @property_account = accounts(:property)
  end

  test "property overview success and failure feedback are localized" do
    patch property_path(@property_account, locale: "zh-CN"), params: { account: { name: "Synthetic property name" } }
    assert_response :success
    assert_includes response.parsed_body.text, "房产详情已更新。"
    assert_equal "Synthetic property name", @property_account.reload.name
    Account.any_instance.stubs(:update).returns(false)
    patch property_path(@property_account, locale: "zh-CN"), params: { account: { name: "Unpersisted name" } }
    assert_response :unprocessable_entity
    assert_includes response.parsed_body.text, "无法更新房产详情。"
    assert_equal "Synthetic property name", @property_account.reload.name
  end

  test "property balance success feedback is localized" do
    Account.any_instance.stubs(:set_current_balance).returns(OpenStruct.new(success?: true))
    patch update_balances_property_path(@property_account, locale: "zh-CN"), params: { account: { balance: 100, currency: "USD" } }
    assert_response :success
    assert_includes response.parsed_body.text, "余额已更新。"
  end

  test "property address success and failure feedback are localized" do
    patch update_address_property_path(@property_account, locale: "zh-CN"), params: {
      property: { address_attributes: { line1: "Synthetic address", locality: "Synthetic city", country: "US" } }
    }
    assert_response :success
    assert_includes response.parsed_body.text, "地址已更新。"
    assert_equal "Synthetic address", @property_account.reload.property.address.line1
    Property.any_instance.stubs(:update).returns(false)
    patch update_address_property_path(@property_account, locale: "zh-CN"), params: { property: { address_attributes: { line1: "" } } }
    assert_response :unprocessable_entity
    assert_includes response.parsed_body.text, "无法更新地址，请检查必填字段。"
    assert_equal "Synthetic address", @property_account.reload.property.address.line1
  end

  %w[fr hu].each do |locale|
    test "#{locale} usage display localizes operations dates and USD without changing records" do
      timestamp = Time.zone.local(2026, 1, 2, 13, 14)
      usage = @user.family.llm_usages.create!(provider: "synthetic", model: "synthetic-model", operation: "auto_categorize",
        prompt_tokens: 2, completion_tokens: 3, total_tokens: 5, estimated_cost: BigDecimal("1234.56789"), created_at: timestamp)
      unknown = "synthetic_<script>alert(1)</script>_operation"
      @user.family.llm_usages.create!(provider: "synthetic", model: "synthetic-model", operation: unknown,
        prompt_tokens: 0, completion_tokens: 0, total_tokens: 0, estimated_cost: nil, created_at: timestamp)
      get settings_llm_usage_path(locale: locale, start_date: "2026-01-01", end_date: "2026-01-31")
      assert_response :success
      expected_operation = locale == "fr" ? "Catégorisation automatique" : "Automatikus kategorizálás"
      assert_includes response.parsed_body.text, expected_operation
      assert_includes response.parsed_body.text, unknown
      assert_select "script", text: "alert(1)", count: 0
      timestamps = response.parsed_body.css("time[datetime=\"#{timestamp.iso8601}\"]")
      assert_equal 2, timestamps.size
      timestamps.each { |node| assert_equal I18n.l(timestamp, locale: locale, format: :long), node.text }
      assert_includes response.parsed_body.text, "N/A"
      separator = " " # Both locale resources explicitly use a space for grouping.
      assert_includes response.parsed_body.text, "1#{separator}234,5679"
      assert_includes response.parsed_body.text, "1#{separator}234,57"
      assert_includes response.parsed_body.text, "$"
      refute_includes response.parsed_body.text, "Ft"
      assert_equal BigDecimal("1234.56789"), usage.reload.estimated_cost
      assert_equal "auto_categorize", usage.operation
      assert_equal timestamp, usage.created_at
    end
  end

  test "English usage row retains its original rounded decimal precision" do
    { "one" => BigDecimal("1"), "small" => BigDecimal("0.00001"), "fraction" => BigDecimal("1.23001") }.each do |name, cost|
      @user.family.llm_usages.create!(provider: "synthetic", model: name, operation: "chat", prompt_tokens: 0,
        completion_tokens: 0, total_tokens: 0, estimated_cost: cost)
    end
    get settings_llm_usage_path(locale: "en")
    assert_response :success
    costs = response.parsed_body.css("tbody tr").to_h do |row|
      cells = row.css("td")
      [ cells[2].text.strip, cells[4].text.strip ]
    end
    assert_equal "$1.0", costs.fetch("one")
    assert_equal "$0.0", costs.fetch("small")
    assert_equal "$1.23", costs.fetch("fraction")
  end
end

class Psd2AccountTypeLocalizationTest < ActiveSupport::TestCase
  TYPES = {
    "CACC" => "depositories.subtypes.checking.long",
    "SVGS" => "depositories.subtypes.savings.long",
    "CARD" => "enable_banking_items.account_types.card",
    "CRCD" => "accounts.types.credit_card",
    "LOAN" => "accounts.types.loan",
    "MORT" => "loans.subtypes.mortgage.long",
    "ODFT" => "enable_banking_items.account_types.overdraft",
    "CASH" => "depositories.subtypes.cash.long",
    "TRAN" => "enable_banking_items.account_types.transacting",
    "SALA" => "enable_banking_items.account_types.salary",
    "MOMA" => "depositories.subtypes.money_market.long",
    "NREX" => "enable_banking_items.account_types.non_resident_external",
    "TAXE" => "enable_banking_items.account_types.tax",
    "TRAS" => "enable_banking_items.account_types.cash_trading",
    "ONDP" => "enable_banking_items.account_types.overnight_deposit"
  }.freeze

  test "all known PSD2 display codes use explicit locale resources without changing suggestions" do
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      I18n.with_locale(locale) do
        TYPES.each do |code, key|
          assert I18n.exists?(key, locale, fallback: false), "#{locale} missing #{key}"
          account = EnableBankingAccount.new(account_type: code)
          assert_equal I18n.t(key, fallback: false, raise: true), account.account_type_display
          assert_equal account.account_type_display, EnableBankingAccount.new(account_type: code.downcase).account_type_display
          expected = EnableBankingAccount::CASH_ACCOUNT_TYPE_MAP[code]
          expected&.dig(:type) ? assert_equal(expected[:type], account.suggested_account_type) : assert_nil(account.suggested_account_type)
          expected&.dig(:subtype) ? assert_equal(expected[:subtype], account.suggested_subtype) : assert_nil(account.suggested_subtype)
        end
      end
    end
  end

  test "unknown PSD2 codes preserve the original supplied text and nil stays nil" do
    raw = "unknown_<synthetic>_type"
    I18n.with_locale(:fr) do
      assert_equal raw, EnableBankingAccount.new(account_type: raw).account_type_display
      assert_nil EnableBankingAccount.new(account_type: nil).account_type_display
    end
  end
end
