# frozen_string_literal: true

require "test_helper"
require "openssl"
require_relative "../support/enable_banking_fixture_fence_helper"

class EnableBankingItemsControllerTest < ActionDispatch::IntegrationTest
  include EnableBankingFixtureFenceHelper
  setup do
    DebugLogEntry.stubs(:capture)
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

  test "raw item UUID and malformed state cannot enter callback session exchange" do
    Provider::EnableBanking.any_instance.expects(:create_session).never
    [ @item.id, "forged-state" ].each do |state|
      get callback_enable_banking_items_url, params: { state: state, code: "private-single-use-code" }
      assert_redirected_to settings_providers_path
      assert_response :see_other
      refute_includes flash[:alert], "private-single-use-code"
    end
  end

  test "callback requires admin before looking up signed state" do
    sign_in users(:family_member)
    EnableBankingItem::Lifecycle.expects(:from_state).never
    get callback_enable_banking_items_url, params: { state: "anything", code: "private-code" }
    assert_redirected_to accounts_path
  end

  test "successful signed callback invokes exact command and does not enqueue a second sync" do
    command = mock("admitted consent")
    EnableBankingItem::Lifecycle.expects(:from_state).with("signed-state", actor: users(:family_admin)).returns(command)
    command.expects(:complete_authorization).with(code: "private-code", last_psu_ip: anything).returns(@item)
    EnableBankingItem.any_instance.expects(:sync_later).never
    get callback_enable_banking_items_url, params: { state: "signed-state", code: "private-code" }
    assert_redirected_to accounts_path
    assert_response :see_other
  end

  test "callback provider failures never echo descriptions and diagnostic failure cannot mask refusal" do
    command = mock("admitted refusal")
    EnableBankingItem::Lifecycle.expects(:from_state).returns(command)
    command.expects(:complete_authorization).raises(IOError, "private-code private-response")
    DebugLogEntry.stubs(:capture).raises("diagnostic unavailable")
    get callback_enable_banking_items_url, params: { state: "signed-state", code: "private-code" }
    assert_redirected_to settings_providers_path
    assert_response :see_other
    refute_includes flash[:alert], "private"
  end

  test "provider callback denial consumes only its verified current authorization" do
    command = mock("admitted denied authorization")
    EnableBankingItem::Lifecycle.expects(:from_state).with("signed-state", actor: users(:family_admin)).returns(command)
    command.expects(:authorization_failed!)
    command.expects(:complete_authorization).never
    get callback_enable_banking_items_url, params: { state: "signed-state", error: "private-error", error_description: "private-description" }
    assert_redirected_to settings_providers_path
    refute_includes flash[:alert], "private"
  end

  test "disconnect refusal does not call old revoke or schedule deletion" do
    EnableBankingItem::Lifecycle.any_instance.expects(:disconnect).raises(EnableBankingItem::Lifecycle::Fence::OwnershipChanged)
    EnableBankingItem.any_instance.expects(:revoke_session).never
    EnableBankingItem.any_instance.expects(:destroy_later).never
    delete enable_banking_item_url(@item)
    assert_redirected_to settings_providers_path
    assert_response :see_other
    assert_not @item.reload.scheduled_for_deletion?
    assert flash[:alert]
  end

  test "configuration updates preserve owner refusal and original credentials" do
    original = @item.attributes
    EnableBankingItem::Lifecycle.any_instance.expects(:update_settings).raises(EnableBankingItem::Lifecycle::Fence::OwnershipChanged)
    patch enable_banking_item_url(@item), params: { enable_banking_item: { application_id: "replacement" } }
    assert_redirected_to settings_providers_path
    assert_equal original, @item.reload.attributes
  end

  test "request logging filters exact consent secrets without hiding country or transaction status fields" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter("code" => "private-code", "state" => "signed-state", "error_description" => "private-body",
      "country_code" => "FI", "status" => "good", "account_state" => "active")
    %w[code state error_description].each { |key| assert_equal "[FILTERED]", filtered.fetch(key) }
    assert_equal "FI", filtered.fetch("country_code")
    assert_equal "good", filtered.fetch("status")
    assert_equal "active", filtered.fetch("account_state")
  end
end
