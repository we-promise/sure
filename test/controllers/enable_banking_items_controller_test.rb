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

  test "authorize picks REDIRECT when ASPSP exposes both REDIRECT and DECOUPLED" do
    # Handelsbanken SE is the motivating case: EB returns DECOUPLED first in the
    # auth_methods list, and without an explicit auth_method picks DECOUPLED.
    Provider::EnableBanking.any_instance.stubs(:get_aspsps).returns(
      aspsps: [
        {
          name: "Handelsbanken",
          country: "SE",
          psu_types: [ "personal" ],
          auth_methods: [
            { name: "decoupled-bankid", approach: "DECOUPLED" },
            { name: "redirect-bankid",  approach: "REDIRECT"  }
          ]
        }
      ]
    )

    Provider::EnableBanking.any_instance.expects(:start_authorization).with do |args|
      args[:auth_method] == "redirect-bankid"
    end.returns(url: "https://api.enablebanking.com/auth/x", authorization_id: "auth_1")

    post authorize_enable_banking_item_url(@item), params: { aspsp_name: "Handelsbanken" }

    assert_redirected_to "https://api.enablebanking.com/auth/x"
    assert_nil flash[:alert]
    assert_equal "REDIRECT", @item.reload.aspsp_auth_approach
  end

  test "authorize rejects ASPSPs whose only auth_method is DECOUPLED" do
    Provider::EnableBanking.any_instance.stubs(:get_aspsps).returns(
      aspsps: [
        {
          name: "DecoupledOnly Bank",
          country: "DE",
          psu_types: [ "personal" ],
          auth_methods: [ { name: "decoupled-only", approach: "DECOUPLED" } ]
        }
      ]
    )

    Provider::EnableBanking.any_instance.expects(:start_authorization).never

    post authorize_enable_banking_item_url(@item), params: { aspsp_name: "DecoupledOnly Bank" }

    assert_redirected_to settings_providers_path
    assert_match(/separate-device/i, flash[:alert])
  end

  test "authorize without explicit auth_method for single-method REDIRECT banks" do
    # Backward-compat: single-method REDIRECT banks should still work and the
    # selected auth_method's name should be forwarded if present.
    Provider::EnableBanking.any_instance.stubs(:get_aspsps).returns(
      aspsps: [
        {
          name: "ING-DiBa AG",
          country: "DE",
          psu_types: [ "personal" ],
          auth_methods: [ { name: "ing-redirect", approach: "REDIRECT" } ]
        }
      ]
    )

    Provider::EnableBanking.any_instance.expects(:start_authorization).with do |args|
      args[:auth_method] == "ing-redirect"
    end.returns(url: "https://api.enablebanking.com/auth/x", authorization_id: "auth_1")

    post authorize_enable_banking_item_url(@item), params: { aspsp_name: "ING-DiBa AG" }

    assert_redirected_to "https://api.enablebanking.com/auth/x"
  end

  test "authorize surfaces an EB catalog-fetch failure as an alert (fails closed)" do
    # We intentionally don't fall back to "let EB pick" when get_aspsps raises:
    # that would silently regress multi-method banks like Handelsbanken to
    # EB's DECOUPLED default the moment EB has a hiccup. Surface the error
    # to the user instead.
    Provider::EnableBanking.any_instance.stubs(:get_aspsps).raises(
      Provider::EnableBanking::EnableBankingError.new("upstream timeout", :request_failed)
    )
    Provider::EnableBanking.any_instance.expects(:start_authorization).never

    post authorize_enable_banking_item_url(@item), params: { aspsp_name: "Handelsbanken" }

    assert_redirected_to settings_providers_path
    assert_match(/upstream timeout/i, flash[:alert])
  end

  test "authorize proceeds (no rejection) when EB returns no auth_methods at all" do
    # Backward-compat: if EB's catalog entry has missing/empty auth_methods we
    # let the request through without an explicit auth_method, so EB falls back
    # to its own default. Previously this code path was implicit; the regression
    # is that we must NOT reject when methods are unknown.
    Provider::EnableBanking.any_instance.stubs(:get_aspsps).returns(
      aspsps: [
        {
          name: "MysteryBank",
          country: "DE",
          psu_types: [ "personal" ]
          # no auth_methods key at all
        }
      ]
    )

    Provider::EnableBanking.any_instance.expects(:start_authorization).with do |args|
      args[:auth_method].nil?
    end.returns(url: "https://api.enablebanking.com/auth/x", authorization_id: "auth_1")

    post authorize_enable_banking_item_url(@item), params: { aspsp_name: "MysteryBank" }

    assert_redirected_to "https://api.enablebanking.com/auth/x"
    assert_nil flash[:alert]
  end

  test "reauthorize rejects when the bank's catalog entry has regressed to DECOUPLED-only" do
    # A bank that originally exposed REDIRECT may have changed its EB catalog
    # entry to DECOUPLED-only between connect and the 90-day reauth. Mirror the
    # authorize-action guard so the user gets the same actionable alert instead
    # of an EB URL the web flow can't complete.
    @item.update_columns(aspsp_name: "DecoupledNow Bank")
    Provider::EnableBanking.any_instance.stubs(:get_aspsps).returns(
      aspsps: [
        {
          name: "DecoupledNow Bank",
          country: "DE",
          psu_types: [ "personal" ],
          auth_methods: [ { name: "dec-only", approach: "DECOUPLED" } ]
        }
      ]
    )
    Provider::EnableBanking.any_instance.expects(:start_authorization).never

    post reauthorize_enable_banking_item_url(@item)

    assert_redirected_to settings_providers_path
    assert_match(/separate-device/i, flash[:alert])
  end

  test "reauthorize rejects items with missing aspsp_name instead of calling EB" do
    # Half-completed initial connections can land with aspsp_name = nil (e.g.
    # EB session creation failed mid-flow). Without the guard, reauthorize
    # would POST /auth with body.aspsp.name = null and surface a confusing
    # WRONG_REQUEST_PARAMETERS alert to the user.
    @item.update_columns(aspsp_name: nil)
    Provider::EnableBanking.any_instance.expects(:get_aspsps).never
    Provider::EnableBanking.any_instance.expects(:start_authorization).never

    post reauthorize_enable_banking_item_url(@item)

    assert_redirected_to settings_providers_path
    assert_match(/missing a bank/i, flash[:alert])
  end
end
