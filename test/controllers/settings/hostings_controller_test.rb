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

  test "can update onboarding state when self hosting is enabled" do
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
end
