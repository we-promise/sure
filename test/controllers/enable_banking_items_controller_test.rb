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

  test "select existing account shows provider-bounded sync start date" do
    get select_existing_account_enable_banking_items_url, params: { account_id: accounts(:depository).id }

    assert_response :success
    assert_select "input[name=sync_start_date][type=date][required]" do |fields|
      assert_equal EnableBankingItem.minimum_sync_start_date.to_s, fields.first["min"]
      assert_equal Date.current.to_s, fields.first["max"]
    end
  end

  test "link existing account persists sync date and starts historical sync" do
    manual_account = accounts(:depository)
    provider_account = @item.enable_banking_accounts.create!(
      name: "Current account",
      uid: "link-date-test",
      currency: "EUR"
    )
    selected_date = 1.year.ago.to_date

    post link_existing_account_enable_banking_items_url, params: {
      account_id: manual_account.id,
      enable_banking_account_id: provider_account.id,
      sync_start_date: selected_date.iso8601
    }

    assert_response :see_other
    assert_match %r{/accounts\?cache_bust=}, response.location
    assert_equal manual_account, provider_account.reload.account
    assert_equal selected_date, provider_account.sync_start_date
    assert_equal selected_date, @item.reload.sync_start_date
    assert_equal selected_date, @item.syncs.order(:created_at).last.window_start_date
  end

  test "link existing account rejects a date outside the provider limit" do
    provider_account = @item.enable_banking_accounts.create!(
      name: "Current account",
      uid: "invalid-link-date-test",
      currency: "EUR"
    )

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_enable_banking_items_url, params: {
        account_id: accounts(:depository).id,
        enable_banking_account_id: provider_account.id,
        sync_start_date: (EnableBankingItem.minimum_sync_start_date - 1.day).iso8601
      }
    end

    assert_redirected_to account_path(accounts(:depository))
    assert_nil provider_account.reload.sync_start_date
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
end
