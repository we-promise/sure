require "test_helper"
require "ostruct"

class Settings::HostingsControllerTest < ActionDispatch::IntegrationTest
  include ProviderTestHelper

  setup do
    sign_in users(:family_admin)

    @provider = mock
    Provider::Registry.stubs(:get_provider).with(:twelve_data).returns(@provider)

    @provider.stubs(:health_status).returns(:healthy)
    Provider::Registry.stubs(:get_provider).with(:yahoo_finance).returns(@provider)
    Provider::Registry.stubs(:get_provider).with(:rentcast).returns(nil)
    Provider::Registry.stubs(:get_provider).with(:realie).returns(nil)
    @provider.stubs(:usage).returns(provider_success_response(
      OpenStruct.new(
        used: 10,
        limit: 100,
        utilization: 10,
        plan: "free",
      )
    ))
  end

  teardown do
    # These tests persist global Setting.* values; reset them so state can't
    # leak into later (order-dependent) tests.
    %i[anthropic_access_token anthropic_base_url anthropic_model llm_provider rentcast_api_key realie_api_key].each do |key|
      Setting.public_send("#{key}=", nil)
    end
  end

  test "cannot edit when self hosting is disabled" do
    @provider.stubs(:usage).returns(@usage_response)

    Rails.configuration.stubs(:app_mode).returns("managed".inquiry)
    get settings_hosting_url
    assert_response :forbidden

    patch settings_hosting_url, params: { setting: { onboarding_state: "invite_only" } }
    assert_response :forbidden
  end

  test "should get edit when self hosting is enabled" do
    @provider.expects(:usage).returns(@usage_response)

    with_self_hosting do
      get settings_hosting_url
      assert_response :success
    end
  end

  test "can update rentcast api key when self hosting is enabled" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { rentcast_api_key: "rentcast-token" } }

      assert_equal "rentcast-token", Setting.rentcast_api_key
    end
  end

  test "can update realie api key when self hosting is enabled" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { realie_api_key: "realie-token" } }

      assert_equal "realie-token", Setting.realie_api_key
    end
  end

  test "shows Yahoo Finance rate limiting as a warning" do
    @provider.stubs(:health_status).returns(:rate_limited)

    with_env_overrides("EXCHANGE_RATE_PROVIDER" => "yahoo_finance") do
      with_self_hosting do
        get settings_hosting_url

        assert_response :success
        assert_select "div[class~=?]", "bg-warning/10"
        assert_includes response.body, "Yahoo Finance is temporarily rate limiting requests."
        assert_includes response.body, "Yahoo Finance rate limit reached."
        assert_includes response.body, "No action is required."
        assert_not_includes response.body, "firewall"
      end
    end
  end

  test "renders healthy unavailable and unknown Yahoo Finance states" do
    @provider.stubs(:health_status).returns(:healthy, :unavailable, :unknown)

    with_env_overrides("EXCHANGE_RATE_PROVIDER" => "yahoo_finance") do
      with_self_hosting do
        get settings_hosting_url
        assert_includes response.body, "Yahoo Finance is active and working."
        assert_select "div[class~=?]", "bg-success"

        get settings_hosting_url
        assert_includes response.body, "Yahoo Finance is currently unavailable."
        assert_includes response.body, "Could not verify Yahoo Finance."
        assert_includes response.body, "Check your internet connection and try again later."
        assert_not_includes response.body, "firewall"
        assert_select "div[class~=?]", "bg-destructive"

        get settings_hosting_url
        assert_includes response.body, "Yahoo Finance status is being checked."
        assert_not_includes response.body, "Could not verify Yahoo Finance."
        assert_not_includes response.body, "Yahoo Finance rate limit reached."
        assert_select "div[class~=?]", "bg-surface-inset"
      end
    end
  end

  test "renders Spanish Yahoo Finance health guidance" do
    @provider.stubs(:health_status).returns(:rate_limited, :unavailable, :unknown)

    with_env_overrides("EXCHANGE_RATE_PROVIDER" => "yahoo_finance") do
      with_self_hosting do
        get settings_hosting_url(locale: :es)
        assert_includes response.body, "Yahoo Finance está limitando temporalmente las solicitudes."
        assert_includes response.body, "No es necesario realizar ninguna acción."

        get settings_hosting_url(locale: :es)
        assert_includes response.body, "Yahoo Finance no está disponible en este momento."
        assert_includes response.body, "Comprueba tu conexión a internet"

        get settings_hosting_url(locale: :es)
        assert_includes response.body, "Se está comprobando el estado de Yahoo Finance."
      end
    end
  end

  test "falls back to English for untranslated Yahoo Finance health guidance" do
    @provider.stubs(:health_status).returns(:rate_limited)

    with_env_overrides("EXCHANGE_RATE_PROVIDER" => "yahoo_finance") do
      with_self_hosting do
        get settings_hosting_url(locale: :fr)

        assert_includes response.body, "Yahoo Finance is temporarily rate limiting requests."
        assert_not_includes response.body, "translation missing"
      end
    end
  end

  test "can update settings when self hosting is enabled" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { twelve_data_api_key: "1234567890" } }

      assert_equal "1234567890", Setting.twelve_data_api_key
    end
  end

  test "can update onboarding state when self hosting is enabled" do
    sign_in users(:sure_support_staff)

    with_self_hosting do
      patch settings_hosting_url, params: { setting: { onboarding_state: "invite_only" } }

      assert_equal "invite_only", Setting.onboarding_state
      assert Setting.require_invite_for_signup

      patch settings_hosting_url, params: { setting: { onboarding_state: "closed" } }

      assert_equal "closed", Setting.onboarding_state
      refute Setting.require_invite_for_signup
    end
  end

  test "can update openai access token when self hosting is enabled" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { openai_access_token: "token" } }

      assert_equal "token", Setting.openai_access_token
    end
  end

  test "can update anthropic access token when self hosting is enabled" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { anthropic_access_token: "fake-anthropic-key-for-tests" } }

      assert_equal "fake-anthropic-key-for-tests", Setting.anthropic_access_token
    end
  end

  test "ignores redacted anthropic token placeholder" do
    with_self_hosting do
      Setting.anthropic_access_token = "previous-token"

      patch settings_hosting_url, params: { setting: { anthropic_access_token: "********" } }

      assert_equal "previous-token", Setting.anthropic_access_token
    end
  end

  test "can update anthropic base_url and model" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { anthropic_base_url: "https://bedrock.example.com", anthropic_model: "claude-opus-4-7" } }

      assert_equal "https://bedrock.example.com", Setting.anthropic_base_url
      assert_equal "claude-opus-4-7", Setting.anthropic_model
    end
  end

  test "rejects non-URL anthropic base_url" do
    with_self_hosting do
      Setting.anthropic_base_url = nil

      patch settings_hosting_url, params: { setting: { anthropic_base_url: "not-a-url" } }

      assert_response :unprocessable_entity
      assert_match(/Anthropic Base URL must be an http/, flash[:alert])
      assert_nil Setting.anthropic_base_url
    end
  end

  test "clears anthropic base_url when blank value submitted" do
    with_self_hosting do
      Setting.anthropic_base_url = "https://bedrock.example.com"

      patch settings_hosting_url, params: { setting: { anthropic_base_url: "" } }

      assert_nil Setting.anthropic_base_url
    end
  end

  test "requires anthropic model when a custom base_url is set" do
    with_self_hosting do
      Setting.anthropic_base_url = nil
      Setting.anthropic_model = nil

      patch settings_hosting_url, params: { setting: { anthropic_base_url: "https://bedrock.example.com" } }

      assert_response :unprocessable_entity
      assert_match(/Anthropic Model is required/, flash[:alert])
      assert_nil Setting.anthropic_base_url
    end
  end

  test "can update llm_provider to anthropic" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { llm_provider: "anthropic" } }

      assert_equal "anthropic", Setting.llm_provider
    end
  end

  test "falls back to openai when stored llm_provider is invalid" do
    with_self_hosting do
      Setting.llm_provider = "bogus"
      Provider::Openai.stubs(:configured?).returns(false)

      get settings_hosting_url

      assert_response :success
      assert_select "select[name=?] option[selected][value=?]", "setting[llm_provider]", "openai"
      assert_no_match(/translation missing/i, @response.body)
    end
  ensure
    Setting.llm_provider = nil
  end

  test "rejects unknown llm_provider values" do
    with_self_hosting do
      Setting.llm_provider = "openai"

      patch settings_hosting_url, params: { setting: { llm_provider: "bogus" } }

      assert_equal "openai", Setting.llm_provider
    end
  end

  test "can update openai uri base and model together when self hosting is enabled" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { openai_uri_base: "https://api.example.com/v1", openai_model: "gpt-4" } }

      assert_equal "https://api.example.com/v1", Setting.openai_uri_base
      assert_equal "gpt-4", Setting.openai_model
    end
  end

  test "cannot update openai uri base without model when self hosting is enabled" do
    with_self_hosting do
      Setting.openai_model = ""

      patch settings_hosting_url, params: { setting: { openai_uri_base: "https://api.example.com/v1" } }

      assert_response :unprocessable_entity
      assert_match(/OpenAI model is required/, flash[:alert])
      assert Setting.openai_uri_base.blank?, "Expected openai_uri_base to remain blank after failed validation"
    end
  end

  # Regression: issue #1824. The OpenAI form auto-submits on blur, so entering
  # the URI base before the model fires a partial submit that fails validation.
  # The re-rendered form must show the user's submitted URI base — not the
  # still-blank saved value — so they can finish typing the model.
  test "preserves submitted openai uri base in form when validation fails" do
    with_self_hosting do
      Setting.openai_uri_base = nil
      Setting.openai_model = ""

      patch settings_hosting_url, params: { setting: { openai_uri_base: "https://api.example.com/v1" } }

      assert_response :unprocessable_entity
      assert_select "input[name=?]", "setting[openai_uri_base]" do |inputs|
        assert_equal "https://api.example.com/v1", inputs.first["value"]
      end
    end
  ensure
    Setting.openai_uri_base = nil
    Setting.openai_model = nil
  end

  # PR #1862 review (jjmata): symmetric coverage for the model field. When the
  # user changes the URI base and clears the model in the same auto-submit, the
  # cross-field validation fails — the re-rendered model input must reflect the
  # user's submitted (cleared) value, not silently revert to the saved model.
  test "preserves submitted openai model in form when validation fails" do
    with_self_hosting do
      Setting.openai_uri_base = "https://saved.example.com/v1"
      Setting.openai_model = "saved-model"

      patch settings_hosting_url, params: { setting: {
        openai_uri_base: "https://new.example.com/v1",
        openai_model: ""
      } }

      assert_response :unprocessable_entity
      assert_select "input[name=?]", "setting[openai_uri_base]" do |inputs|
        assert_equal "https://new.example.com/v1", inputs.first["value"]
      end
      assert_select "input[name=?]", "setting[openai_model]" do |inputs|
        assert_not_equal "saved-model", inputs.first["value"].to_s,
          "model field must reflect the submitted (cleared) value, not the saved model"
      end
    end
  ensure
    Setting.openai_uri_base = nil
    Setting.openai_model = nil
  end

  test "can update openai model alone when self hosting is enabled" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { openai_model: "gpt-4" } }

      assert_equal "gpt-4", Setting.openai_model
    end
  end

  test "cannot clear openai model when custom uri base is set" do
    with_self_hosting do
      Setting.openai_uri_base = "https://api.example.com/v1"
      Setting.openai_model = "gpt-4"

      patch settings_hosting_url, params: { setting: { openai_model: "" } }

      assert_response :unprocessable_entity
      assert_match(/OpenAI model is required/, flash[:alert])
      assert_equal "gpt-4", Setting.openai_model
    end
  end

  test "can clear data cache when self hosting is enabled" do
    account = accounts(:investment)
    holding = account.holdings.first
    exchange_rate = exchange_rates(:one)
    security_price = holding.security.prices.first
    account_balance = account.balances.create!(date: Date.current, balance: 1000, currency: "USD")

    with_self_hosting do
      perform_enqueued_jobs(only: DataCacheClearJob) do
        delete clear_cache_settings_hosting_url
      end
    end

    assert_redirected_to settings_hosting_url
    assert_equal I18n.t("settings.hostings.clear_cache.cache_cleared"), flash[:notice]

    assert_not ExchangeRate.exists?(exchange_rate.id)
    assert_not Security::Price.exists?(security_price.id)
    assert_not Holding.exists?(holding.id)
    assert_not Balance.exists?(account_balance.id)
  end

  test "can update assistant type to external" do
    with_self_hosting do
      assert_equal "builtin", users(:family_admin).family.assistant_type

      patch settings_hosting_url, params: { family: { assistant_type: "external" } }

      assert_redirected_to settings_hosting_url
      assert_equal "external", users(:family_admin).family.reload.assistant_type
    end
  end

  test "ignores invalid assistant type values" do
    with_self_hosting do
      patch settings_hosting_url, params: { family: { assistant_type: "hacked" } }

      assert_redirected_to settings_hosting_url
      assert_equal "builtin", users(:family_admin).family.reload.assistant_type
    end
  end

  test "ignores assistant type update when ASSISTANT_TYPE env is set" do
    with_self_hosting do
      with_env_overrides("ASSISTANT_TYPE" => "external") do
        patch settings_hosting_url, params: { family: { assistant_type: "external" } }

        assert_redirected_to settings_hosting_url
        # DB value should NOT change when env override is active
        assert_equal "builtin", users(:family_admin).family.reload.assistant_type
      end
    end
  end

  test "can update external assistant settings" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: {
        external_assistant_url: "https://agent.example.com/v1/chat",
        external_assistant_token: "my-secret-token",
        external_assistant_agent_id: "finance-bot"
      } }

      assert_redirected_to settings_hosting_url
      assert_equal "https://agent.example.com/v1/chat", Setting.external_assistant_url
      assert_equal "my-secret-token", Setting.external_assistant_token
      assert_equal "finance-bot", Setting.external_assistant_agent_id
    end
  ensure
    Setting.external_assistant_url = nil
    Setting.external_assistant_token = nil
    Setting.external_assistant_agent_id = nil
  end

  test "does not overwrite token with masked placeholder" do
    with_self_hosting do
      Setting.external_assistant_token = "real-secret"

      patch settings_hosting_url, params: { setting: { external_assistant_token: "********" } }

      assert_equal "real-secret", Setting.external_assistant_token
    end
  ensure
    Setting.external_assistant_token = nil
  end

  test "disconnect external assistant clears settings and resets type" do
    with_self_hosting do
      with_env_overrides("EXTERNAL_ASSISTANT_URL" => nil, "EXTERNAL_ASSISTANT_TOKEN" => nil) do
        Setting.external_assistant_url = "https://agent.example.com/v1/chat"
        Setting.external_assistant_token = "token"
        Setting.external_assistant_agent_id = "finance-bot"
        users(:family_admin).family.update!(assistant_type: "external")

        delete disconnect_external_assistant_settings_hosting_url

        assert_redirected_to settings_hosting_url
        # Force cache refresh so configured? reads fresh DB state after
        # the disconnect action cleared the settings within its own request.
        Setting.clear_cache
        assert_not Assistant::External.configured?
        assert_equal "builtin", users(:family_admin).family.reload.assistant_type
      end
    end
  ensure
    Setting.external_assistant_url = nil
    Setting.external_assistant_token = nil
    Setting.external_assistant_agent_id = nil
  end

  test "disconnect external assistant requires admin" do
    with_self_hosting do
      sign_in users(:family_member)
      delete disconnect_external_assistant_settings_hosting_url

      assert_redirected_to settings_hosting_url
      assert_equal I18n.t("settings.hostings.not_authorized"), flash[:alert]
    end
  end

  test "accepts valid llm budget overrides and blanks clear them" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: {
        llm_context_window: "4096",
        llm_max_response_tokens: "1024",
        llm_max_items_per_call: "40"
      } }

      assert_redirected_to settings_hosting_url
      assert_equal 4096, Setting.llm_context_window
      assert_equal 1024, Setting.llm_max_response_tokens
      assert_equal 40, Setting.llm_max_items_per_call

      patch settings_hosting_url, params: { setting: {
        llm_context_window: "",
        llm_max_response_tokens: "",
        llm_max_items_per_call: ""
      } }

      assert_nil Setting.llm_context_window
      assert_nil Setting.llm_max_response_tokens
      assert_nil Setting.llm_max_items_per_call
    end
  ensure
    Setting.llm_context_window = nil
    Setting.llm_max_response_tokens = nil
    Setting.llm_max_items_per_call = nil
  end

  test "rejects llm budget below field minimum" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { llm_context_window: "0" } }

      assert_response :unprocessable_entity
      assert_match(/must be a whole number/, flash[:alert])
      assert_nil Setting.llm_context_window

      patch settings_hosting_url, params: { setting: { llm_max_response_tokens: "-5" } }

      assert_response :unprocessable_entity
      assert_match(/must be a whole number/, flash[:alert])
      assert_nil Setting.llm_max_response_tokens

      patch settings_hosting_url, params: { setting: { llm_max_items_per_call: "not-a-number" } }

      assert_response :unprocessable_entity
      assert_match(/must be a whole number/, flash[:alert])
      assert_nil Setting.llm_max_items_per_call
    end
  ensure
    Setting.llm_context_window = nil
    Setting.llm_max_response_tokens = nil
    Setting.llm_max_items_per_call = nil
  end

  test "can clear data only when admin" do
    with_self_hosting do
      sign_in users(:family_member)

      assert_no_enqueued_jobs do
        delete clear_cache_settings_hosting_url
      end

      assert_redirected_to settings_hosting_url
      assert_equal I18n.t("settings.hostings.not_authorized"), flash[:alert]
    end
  end

  # --- Securities provider toggle ---

  test "can update securities providers" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { securities_providers: [ "twelve_data", "yahoo_finance" ] } }

      assert_redirected_to settings_hosting_url
      assert_equal "twelve_data,yahoo_finance", Setting.securities_providers
    end
  ensure
    Setting.securities_providers = ""
  end

  test "filters out invalid provider names" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { securities_providers: [ "twelve_data", "fake_provider", "hacked" ] } }

      assert_redirected_to settings_hosting_url
      # Only valid providers are stored
      enabled = Setting.enabled_securities_providers
      assert_includes enabled, "twelve_data"
      refute_includes enabled, "fake_provider"
      refute_includes enabled, "hacked"
    end
  ensure
    Setting.securities_providers = ""
  end

  test "removing a provider marks linked securities offline" do
    with_self_hosting do
      security = Security.create!(ticker: "CSPX", exchange_operating_mic: "XLON", price_provider: "tiingo", offline: false)

      # First enable tiingo
      Setting.securities_providers = "twelve_data,tiingo"

      # Then remove tiingo
      patch settings_hosting_url, params: { setting: { securities_providers: [ "twelve_data" ] } }

      security.reload
      assert security.offline?, "Security should be marked offline when its provider is removed"
      assert_equal "provider_disabled", security.offline_reason
    end
  ensure
    Setting.securities_providers = ""
  end

  test "re-adding a provider brings securities back online" do
    with_self_hosting do
      security = Security.create!(
        ticker: "CSPX2", exchange_operating_mic: "XLON",
        price_provider: "tiingo", offline: true, offline_reason: "provider_disabled"
      )

      # Start without tiingo
      Setting.securities_providers = "twelve_data"

      # Re-add tiingo
      patch settings_hosting_url, params: { setting: { securities_providers: [ "twelve_data", "tiingo" ] } }

      security.reload
      refute security.offline?, "Security should come back online when its provider is re-added"
      assert_nil security.offline_reason
    end
  ensure
    Setting.securities_providers = ""
  end
end
