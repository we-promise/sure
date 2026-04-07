require "test_helper"
require "ostruct"

class Settings::HostingsControllerTest < ActionDispatch::IntegrationTest
  include ProviderTestHelper

  setup do
    sign_in users(:family_admin)

    @provider = mock
    Provider::Registry.stubs(:get_provider).with(:twelve_data).returns(@provider)

    @provider.stubs(:healthy?).returns(true)
    Provider::Registry.stubs(:get_provider).with(:yahoo_finance).returns(@provider)
    @provider.stubs(:usage).returns(provider_success_response(
      OpenStruct.new(
        used: 10,
        limit: 100,
        utilization: 10,
        plan: "free",
      )
    ))
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

  test "can update settings when self hosting is enabled" do
    with_self_hosting do
      patch settings_hosting_url, params: { setting: { twelve_data_api_key: "1234567890" } }

      assert_equal "1234567890", Setting.twelve_data_api_key
    end
  end

  test "can update international inflation provider settings when env overrides are absent" do
    with_self_hosting do
      with_env_overrides(
        "US_BLS_CPI_BASE_URL" => nil,
        "US_BLS_CPI_SERIES_ID" => nil,
        "ES_INE_CPI_BASE_URL" => nil,
        "ES_INE_CPI_SERIES_ID" => nil
      ) do
        patch settings_hosting_url, params: {
          setting: {
            us_bls_cpi_base_url: "https://api.bls.gov/publicAPI/v2",
            us_bls_cpi_series_id: "CUUR0000SA0",
            es_ine_cpi_base_url: "https://servicios.ine.es/wstempus/js/EN/DATOS_SERIE/",
            es_ine_cpi_series_id: "IPC123"
          }
        }

        assert_redirected_to settings_hosting_url
        assert_equal "https://api.bls.gov/publicAPI/v2", Setting.us_bls_cpi_base_url
        assert_equal "CUUR0000SA0", Setting.us_bls_cpi_series_id
        assert_equal "https://servicios.ine.es/wstempus/js/EN/DATOS_SERIE/", Setting.es_ine_cpi_base_url
        assert_equal "IPC123", Setting.es_ine_cpi_series_id
      end
    end
  ensure
    Setting.us_bls_cpi_base_url = nil
    Setting.us_bls_cpi_series_id = nil
    Setting.es_ine_cpi_base_url = nil
    Setting.es_ine_cpi_series_id = nil
  end

  test "can clear stored gus api key when env override is absent" do
    old_val = Setting.gus_sdp_api_key
    with_self_hosting do
      with_env_overrides("GUS_SDP_API_KEY" => nil) do
        Setting.gus_sdp_api_key = "example-client-id"

        patch settings_hosting_url, params: { setting: { clear_gus_sdp_api_key: "1" } }

        assert_redirected_to settings_hosting_url
        assert_nil Setting.gus_sdp_api_key
      end
    end
  ensure
    Setting.gus_sdp_api_key = old_val
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

  test "can enqueue manual inflation import when auto import is disabled" do
    with_self_hosting do
      with_env_overrides("GUS_INFLATION_IMPORT_ENABLED" => nil) do
        old_val = Setting.gus_inflation_import_enabled
        Setting.gus_inflation_import_enabled = false

        begin
          assert_enqueued_with(job: ImportInflationRatesJob, args: [ { start_year: 2015, end_year: 2024, force: true, providers: [ "gus_sdp", "us_bls", "es_ine" ], respect_global_toggle: false } ]) do
            post import_gus_inflation_rates_settings_hosting_url,
                 params: { setting: { gus_inflation_start_year: 2015, gus_inflation_end_year: 2024 } }
          end

          assert_redirected_to settings_hosting_url
          assert_equal I18n.t("settings.hostings.import_gus_inflation_rates.import_enqueued"), flash[:notice]
        ensure
          Setting.gus_inflation_import_enabled = old_val
        end
      end
    end
  end

  test "does not enqueue manual inflation import when auto import is enabled" do
    with_self_hosting do
      with_env_overrides("GUS_INFLATION_IMPORT_ENABLED" => nil) do
        old_val = Setting.gus_inflation_import_enabled
        Setting.gus_inflation_import_enabled = true

        begin
          assert_no_enqueued_jobs only: ImportInflationRatesJob do
            post import_gus_inflation_rates_settings_hosting_url,
                 params: { setting: { gus_inflation_start_year: 2015, gus_inflation_end_year: 2024 } }
          end

          assert_redirected_to settings_hosting_url
          assert_equal I18n.t("settings.hostings.import_gus_inflation_rates.manual_import_disabled_when_auto_enabled"), flash[:alert]
        ensure
          Setting.gus_inflation_import_enabled = old_val
        end
      end
    end
  end

  test "rejects malformed manual gus inflation import years" do
    with_self_hosting do
      with_env_overrides("GUS_INFLATION_IMPORT_ENABLED" => nil) do
        old_val = Setting.gus_inflation_import_enabled
        Setting.gus_inflation_import_enabled = false

        begin
          assert_no_enqueued_jobs only: ImportInflationRatesJob do
            post import_gus_inflation_rates_settings_hosting_url,
                 params: { setting: { gus_inflation_start_year: "2020foo", gus_inflation_end_year: 2024 } }
          end

          assert_redirected_to settings_hosting_url
          assert_equal I18n.t("settings.hostings.import_gus_inflation_rates.invalid_import_range"), flash[:alert]
        ensure
          Setting.gus_inflation_import_enabled = old_val
        end
      end
    end
  end
end
