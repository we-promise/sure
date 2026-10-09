# frozen_string_literal: true

require "test_helper"
require "openssl"

class EnableBankingItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @family = families(:dylan_family)
    @item = @family.enable_banking_items.create!(
      name: "Test Connection",
      country_code: "DE",
      application_id: "test_app_id",
      client_certificate: OpenSSL::PKey::RSA.new(2048).to_pem
    )
  end

  test "select_bank exposes ASPSP BIC in the searchable data attribute" do
    Provider::EnableBanking.any_instance.stubs(:get_aspsps).returns(
      aspsps: [
        {
          name: "ING-DiBa AG",
          country: "DE",
          bic: "INGDDEFF",
          beta: false,
          psu_types: [ "personal" ],
          auth_methods: [ { approach: "REDIRECT" } ]
        }
      ]
    )

    get select_bank_enable_banking_item_url(@item)

    assert_response :success
    haystack = @response.body[/data-bank-search="([^"]*)"/, 1]
    assert haystack, "Expected list items to render a data-bank-search attribute the client filter reads from"
    assert_includes haystack, "ingddeff",
      "Expected the searchable data attribute to include the BIC so users can find banks by BIC code"
    assert_includes haystack, "ing-diba ag",
      "Expected the searchable data attribute to still include the bank name (existing name-search behavior)"
  end

  # Redirecting back to Bank sync would collapse the open connection row.
  test "sync from the panel re-renders the panel in place" do
    post sync_enable_banking_item_url(@item, source: "panel"), as: :turbo_stream

    assert_turbo_stream action: "replace", target: "enable_banking-providers-panel"
    assert_includes response.body, I18n.t("settings.providers.sync_provider_in_progress")
    assert @item.reload.syncing?
  end

  # The Accounts page's Sync button posts here too, without the panel's source.
  test "sync from the Accounts page goes back to it" do
    post sync_enable_banking_item_url(@item),
         headers: { "Accept" => "text/vnd.turbo-stream.html, text/html, application/xhtml+xml", "Referer" => accounts_url }

    assert_redirected_to accounts_url
  end

  test "invalid create outside a frame redirects to the providers page with a 303" do
    assert_no_difference "EnableBankingItem.count" do
      post enable_banking_items_url, params: { enable_banking_item: { country_code: "", application_id: "" } }
    end

    assert_response :see_other
    assert_redirected_to settings_providers_path
    assert_match "can't be blank", flash[:alert]
  end

  test "invalid update outside a frame redirects to the providers page with a 303" do
    patch enable_banking_item_url(@item), params: { enable_banking_item: { country_code: "" } }

    assert_response :see_other
    assert_redirected_to settings_providers_path
    assert_match "can't be blank", flash[:alert]
    assert_equal "DE", @item.reload.country_code
  end

  # Redirecting back to Bank sync collapses the open connection row.
  test "update from the page re-renders the panel in place" do
    patch enable_banking_item_url(@item),
          params: { enable_banking_item: { name: "Renamed Connection" } },
          as: :turbo_stream

    assert_turbo_stream action: "replace", target: "enable_banking-providers-panel"
    assert_includes response.body, %(id="enable_banking-providers-panel")
    assert_equal "Renamed Connection", @item.reload.name
  end

  # The panel never sends a stored certificate back to the browser, so a save
  # that leaves the field blank must keep the one already stored.
  test "an update with a blank certificate keeps the stored one" do
    stored = @item.client_certificate

    patch enable_banking_item_url(@item),
          params: { enable_banking_item: { name: "Renamed Connection", client_certificate: "" } },
          as: :turbo_stream

    assert_turbo_stream action: "replace", target: "enable_banking-providers-panel"
    @item.reload
    assert_equal "Renamed Connection", @item.name
    assert_equal stored, @item.client_certificate
  end

  test "an update with a new certificate replaces the stored one" do
    replacement = OpenSSL::PKey::RSA.new(2048).to_pem

    patch enable_banking_item_url(@item),
          params: { enable_banking_item: { client_certificate: replacement } },
          as: :turbo_stream

    assert_equal replacement, @item.reload.client_certificate
  end

  test "a create still requires a certificate" do
    @item.destroy!

    assert_no_difference "EnableBankingItem.count" do
      post enable_banking_items_url,
           params: { enable_banking_item: { country_code: "DE", application_id: "app", client_certificate: "" } },
           as: :turbo_stream
    end

    assert_response :unprocessable_entity
  end

  test "the panel does not send the stored certificate back to the browser" do
    get connect_form_settings_providers_url(provider_key: "enable_banking")

    assert_response :success
    assert_not_includes response.body, @item.client_certificate.lines.second.strip
    assert_select "textarea[name='enable_banking_item[client_certificate]']" do |fields|
      assert_equal "", fields.first.text.strip
    end
    assert_includes response.body, I18n.t("settings.providers.enable_banking_panel.keep_client_certificate_hint")
  end

  # The application id is the key id of every signed request, so the panel
  # treats it like the certificate: never echoed back, blank keeps it.
  test "the panel does not send the stored application id back to the browser" do
    @item.update_columns(application_id: "stored-app-id-#{SecureRandom.hex(8)}")

    get connect_form_settings_providers_url(provider_key: "enable_banking")

    assert_response :success
    assert_not_includes response.body, @item.application_id
    assert_select "input[name='enable_banking_item[application_id]']" do |fields|
      assert_nil fields.first["value"]
    end
  end

  test "the application id is filtered from logs" do
    parameter_filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered_params = parameter_filter.filter(
      enable_banking_item: { application_id: "stored-app-id", country_code: "DE" }
    )

    assert_equal "[FILTERED]", filtered_params.dig(:enable_banking_item, :application_id)
    assert_equal "DE", filtered_params.dig(:enable_banking_item, :country_code)
  end

  test "an update with a blank application id keeps the stored one" do
    patch enable_banking_item_url(@item),
          params: { enable_banking_item: { name: "Renamed Connection", application_id: "" } },
          as: :turbo_stream

    assert_turbo_stream action: "replace", target: "enable_banking-providers-panel"
    @item.reload
    assert_equal "Renamed Connection", @item.name
    assert_equal "test_app_id", @item.application_id
  end

  test "an update with a new application id replaces the stored one" do
    patch enable_banking_item_url(@item),
          params: { enable_banking_item: { application_id: "replacement_app_id" } },
          as: :turbo_stream

    assert_equal "replacement_app_id", @item.reload.application_id
  end

  test "a create still requires an application id" do
    @item.destroy!

    assert_no_difference "EnableBankingItem.count" do
      post enable_banking_items_url,
           params: { enable_banking_item: { country_code: "DE", application_id: "", client_certificate: OpenSSL::PKey::RSA.new(2048).to_pem } },
           as: :turbo_stream
    end

    assert_response :unprocessable_entity
  end

  test "invalid create from the page shows the error in the panel" do
    post enable_banking_items_url,
         params: { enable_banking_item: { country_code: "", application_id: "" } },
         as: :turbo_stream

    assert_turbo_stream status: :unprocessable_entity, action: "replace", target: "enable_banking-providers-panel"
    assert_includes response.body, ERB::Util.html_escape("can't be blank")
  end

  test "authorize no longer blocks decoupled banks and proceeds to the hosted auth page" do
    Provider::EnableBanking.any_instance.stubs(:get_aspsps).returns(
      aspsps: [
        {
          name: "VR Bank in Holstein",
          country: "DE",
          psu_types: [ "personal" ],
          auth_methods: [ { name: "decoupled_app", approach: "DECOUPLED" } ]
        }
      ]
    )
    Provider::EnableBanking.any_instance.stubs(:start_authorization).returns(
      url: "https://api.enablebanking.com/auth/redirect/abc",
      authorization_id: "auth_1"
    )

    post authorize_enable_banking_item_url(@item),
         params: { aspsp_name: "VR Bank in Holstein", psu_type: "personal" }

    assert_redirected_to "https://api.enablebanking.com/auth/redirect/abc"
    assert_nil flash[:alert]
    assert_equal "DECOUPLED", @item.reload.aspsp_auth_approach
  end

  test "authorize sends a random state instead of the item id" do
    stub_authorization_start

    post authorize_enable_banking_item_url(@item), params: { aspsp_name: "Test Bank", psu_type: "personal" }

    assert_redirected_to "https://api.enablebanking.com/auth/redirect/abc"
    assert_not_equal @item.id, @sent_state
    assert @sent_state.length >= 32
  end

  test "callback completes authorization when the state matches this session" do
    stub_authorization_start
    post authorize_enable_banking_item_url(@item), params: { aspsp_name: "Test Bank", psu_type: "personal" }

    EnableBankingItem.any_instance.expects(:complete_authorization).with(code: "good-code")
    EnableBankingItem.any_instance.stubs(:sync_later)

    get callback_enable_banking_items_url, params: { code: "good-code", state: @sent_state }

    assert_redirected_to accounts_path
  end

  test "callback rejects the item id as state" do
    stub_authorization_start
    post authorize_enable_banking_item_url(@item), params: { aspsp_name: "Test Bank", psu_type: "personal" }

    EnableBankingItem.any_instance.expects(:complete_authorization).never

    get callback_enable_banking_items_url, params: { code: "attacker-code", state: @item.id }

    assert_redirected_to settings_providers_path
  end

  test "callback rejects a state that was not issued to this session" do
    EnableBankingItem.any_instance.expects(:complete_authorization).never

    get callback_enable_banking_items_url, params: { code: "attacker-code", state: SecureRandom.urlsafe_base64(32) }

    assert_redirected_to settings_providers_path
  end

  test "callback state can only be used once" do
    stub_authorization_start
    post authorize_enable_banking_item_url(@item), params: { aspsp_name: "Test Bank", psu_type: "personal" }
    EnableBankingItem.any_instance.stubs(:complete_authorization)
    EnableBankingItem.any_instance.stubs(:sync_later)
    get callback_enable_banking_items_url, params: { code: "good-code", state: @sent_state }

    EnableBankingItem.any_instance.expects(:complete_authorization).never
    get callback_enable_banking_items_url, params: { code: "replayed-code", state: @sent_state }

    assert_redirected_to settings_providers_path
  end

  test "parallel authorizations each keep their own state" do
    stub_authorization_start
    post authorize_enable_banking_item_url(@item), params: { aspsp_name: "Test Bank", psu_type: "personal" }
    first_state = @sent_state
    post authorize_enable_banking_item_url(@item), params: { aspsp_name: "Test Bank", psu_type: "personal" }
    second_state = @sent_state
    EnableBankingItem.any_instance.stubs(:sync_later)

    # A stray callback with a made-up state must not cancel pending flows.
    get callback_enable_banking_items_url, params: { code: "stray", state: "made-up" }

    EnableBankingItem.any_instance.expects(:complete_authorization).twice
    get callback_enable_banking_items_url, params: { code: "first", state: first_state }
    assert_redirected_to accounts_path
    get callback_enable_banking_items_url, params: { code: "second", state: second_state }
    assert_redirected_to accounts_path
  end

  private

    def stub_authorization_start
      Provider::EnableBanking.any_instance.stubs(:get_aspsps).returns(
        aspsps: [ { name: "Test Bank", country: "DE", psu_types: [ "personal" ], auth_methods: [ { approach: "REDIRECT" } ] } ]
      )
      test_case = self
      Provider::EnableBanking.any_instance.stubs(:start_authorization).with do |**kwargs|
        test_case.instance_variable_set(:@sent_state, kwargs[:state])
        true
      end.returns(url: "https://api.enablebanking.com/auth/redirect/abc", authorization_id: "auth_1")
    end
end
