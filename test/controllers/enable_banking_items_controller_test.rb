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
      client_certificate: OpenSSL::PKey::RSA.new(2048).to_pem, sync_start_date: 3.months.ago.to_date
    )
  end

  test "create succeeds without sync_start_date, which is collected later during account setup" do
    assert_difference "EnableBankingItem.count", 1 do
      post enable_banking_items_url, params: {
        enable_banking_item: {
          name: "New Connection",
          country_code: "AT",
          application_id: "new_app_id",
          client_certificate: OpenSSL::PKey::RSA.new(2048).to_pem
        }
      }
    end

    assert_redirected_to settings_providers_path
    item = @family.enable_banking_items.order(:created_at).last
    assert_nil item.sync_start_date
    assert item.date?
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

  test "complete_account_setup persists sync_strategy longest without requiring a date" do
    post complete_account_setup_enable_banking_item_url(@item), params: { sync_strategy: "longest" }

    assert_response :redirect
    @item.reload
    assert @item.longest?
  end

  test "complete_account_setup rejects an out-of-range date instead of raising" do
    post complete_account_setup_enable_banking_item_url(@item), params: {
      sync_strategy: "date", sync_start_date: 3.years.ago.to_date.iso8601
    }

    assert_redirected_to accounts_path
    assert_match "must be within the last 2 years", flash[:alert]
    assert_equal 3.months.ago.to_date, @item.reload.sync_start_date
  end

  test "complete_account_setup ignores params outside its explicit allowlist" do
    original_cert = @item.client_certificate

    post complete_account_setup_enable_banking_item_url(@item), params: {
      sync_strategy: "date", sync_start_date: 1.month.ago.to_date.iso8601,
      client_certificate: "smuggled"
    }

    assert_response :redirect
    assert_equal original_cert, @item.reload.client_certificate
    assert_equal 1.month.ago.to_date, @item.sync_start_date
  end
end
