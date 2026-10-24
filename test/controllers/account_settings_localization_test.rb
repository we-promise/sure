require "test_helper"

class AccountSettingsLocalizationTest < ActionDispatch::IntegrationTest
  NEW_KEYS = %w[
    settings.providers.provider_form.environment_override_hint
    settings.providers.provider_form.optional
    settings.providers.update.failed
    shared.async_loading.timeout
    shared.async_loading.failed_with_status
    shared.async_loading.network_error
    settings.llm_usages.show.http_status
  ].freeze

  setup do
    @user = users(:family_admin)
    @user.family.update!(auto_sync_on_login: false)
    sign_in @user
  end

  test "account notices localize the type without translating user names" do
    Account.any_instance.stubs(:sync_later)
    post depositories_path(locale: "zh-CN"), params: {
      account: { name: "Synthetic user account", balance: 0, currency: "USD", accountable_type: "Depository" }
    }
    assert_response :redirect
    assert_equal I18n.t("accounts.create.success", locale: "zh-CN", type: I18n.t("accounts.types.depository", locale: "zh-CN")), flash[:notice]
    account = @user.family.accounts.find_by!(name: "Synthetic user account")
    patch depository_path(account, locale: "zh-CN"), params: { account: { name: "Untranslated user name" } }
    assert_response :redirect
    assert_equal I18n.t("accounts.update.success", locale: "zh-CN", type: I18n.t("accounts.types.depository", locale: "zh-CN")), flash[:notice]
    assert_equal "Untranslated user name", account.reload.name
  end

  test "property overview buttons localize both active and draft states" do
    account = accounts(:property)
    { "active" => "save", "draft" => "next" }.each do |state, label|
      account.update!(status: state)
      get edit_property_path(account, locale: "zh-CN")
      assert_response :success
      assert_select "button[type=submit]", text: I18n.t("properties.balances.#{label}", locale: "zh-CN")
    end
  end

  test "provider form localizes static hints while keeping supplied field content" do
    field = Struct.new(:setting_key, :env_key, :label, :default, :required, :secret, :description).new(
      "synthetic_ui_option", "SURE_TEST_UI_ENV", "Synthetic field label", nil, false, false, "Synthetic field description"
    )
    config = Struct.new(:provider_key, :fields, :provider_description).new(:synthetic_ui, [ field ], "Synthetic provider description")
    Provider::Factory.ensure_adapters_loaded
    Provider::ConfigurationRegistry.stubs(:all).returns([ config ])
    previous = ENV["SURE_TEST_UI_ENV"]
    ENV["SURE_TEST_UI_ENV"] = "Synthetic environment value"
    get connect_form_settings_providers_path(provider_key: "synthetic_ui", locale: "zh-CN")
    assert_response :success
    assert_includes response.parsed_body.text, "可通过环境变量配置，也可在下方覆盖。"
    assert_select "input[name='setting[synthetic_ui_option]'][placeholder='可选'][value='Synthetic environment value']"
    [ "Synthetic field label", "Synthetic field description", "Synthetic provider description" ].each do |text|
      assert_includes response.parsed_body.text, text
    end
  ensure
    previous.nil? ? ENV.delete("SURE_TEST_UI_ENV") : ENV["SURE_TEST_UI_ENV"] = previous
  end

  test "provider update failure is localized and does not expose internal errors" do
    Provider::Factory.ensure_adapters_loaded
    Setting.expects(:[]=).with("plaid_client_id", "synthetic").raises(StandardError.new("Synthetic internal detail"))
    patch settings_providers_path(locale: "zh-CN"), params: { setting: { plaid_client_id: "synthetic" } }
    assert_response :unprocessable_entity
    assert_equal "更新服务商设置失败，请重试。", flash[:alert]
    refute_includes response.body, "Synthetic internal detail"
  end

  test "avatar preview has localized alternative text" do
    get settings_profile_path(locale: "zh-CN")
    assert_response :success
    assert_select "[data-profile-image-preview-target='previewImage'] img[alt=?]", I18n.t("shared.preview", locale: "zh-CN")
  end

  test "account sparklines receive translated timeout copy" do
    # The account index uses the settings layout; the detail page renders the account sidebar.
    get account_path(accounts(:depository), locale: "zh-CN")
    assert_response :success
    frames = response.parsed_body.css("[data-controller='turbo-frame-timeout']")
    assert frames.any?
    frames.each do |frame|
      assert_equal "超时", frame["data-turbo-frame-timeout-message-value"]
      assert_equal "10000", frame["data-turbo-frame-timeout-timeout-value"]
    end
  end

  test "lazy connection disclosure receives translated errors without connecting" do
    Provider::Snaptrade.stubs(:oauth_configured?).returns(true)
    Provider::Snaptrade.stubs(:authorization_code_configured?).returns(true)
    SnaptradeItem.any_instance.stubs(:oauth_configured?).returns(true)
    get connect_form_settings_providers_path(provider_key: "snaptrade", locale: "zh-CN")
    assert_response :success
    assert_select "[data-controller='lazy-load'][data-lazy-load-failure-message-value='加载失败（%{status}）'][data-lazy-load-network-error-message-value='网络错误']"
  end

  test "LLM usage HTTP status label is localized and status remains unchanged" do
    @user.family.llm_usages.create!(provider: "synthetic", model: "synthetic", operation: "synthetic", prompt_tokens: 0,
      completion_tokens: 0, total_tokens: 0, estimated_cost: 0, metadata: { "http_status_code" => 429, "error" => "Synthetic failure" })
    get settings_llm_usage_path(locale: "zh-CN")
    assert_response :success
    assert_includes response.parsed_body.text, "HTTP 状态：429"
    assert_includes response.parsed_body.text, "Synthetic failure"
  end

  test "all supported locales explicitly translate new display strings" do
    LanguagesHelper::SUPPORTED_LOCALES.each do |locale|
      NEW_KEYS.each do |key|
        assert I18n.exists?(key, locale, fallback: false), "#{locale} missing #{key}"
      end
      assert_includes I18n.t("shared.async_loading.failed_with_status", locale: locale, fallback: false), "%{status}"
      assert_includes I18n.t("settings.llm_usages.show.http_status", locale: locale, fallback: false), "%{status}"
    end
  end
end
