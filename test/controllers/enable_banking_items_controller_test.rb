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

  test "link_accounts propagates the discovered iban to the newly linked account" do
    @item.update!(session_id: "test_session")
    enable_banking_account = @item.enable_banking_accounts.create!(
      uid: "acct_uid_1",
      name: "Checking",
      currency: "EUR",
      iban: "DE89370400440532013000" # pipelock:ignore IBAN
    )

    post link_accounts_enable_banking_items_url,
         params: { account_uids: [ "acct_uid_1" ], accountable_type: "Depository" }

    assert_redirected_to accounts_path
    linked_account = enable_banking_account.reload.account
    assert_not_nil linked_account
    assert_equal "DE89370400440532013000", linked_account.iban # pipelock:ignore IBAN
  end

  test "complete_account_setup propagates the discovered iban to the newly linked account" do
    @item.update!(session_id: "test_session", pending_account_setup: true)
    enable_banking_account = @item.enable_banking_accounts.create!(
      uid: "acct_uid_2",
      name: "Savings",
      currency: "EUR",
      iban: "AT611904300234573201" # pipelock:ignore IBAN
    )

    post complete_account_setup_enable_banking_item_url(@item),
         params: {
           account_types: { enable_banking_account.id.to_s => "Depository" },
           account_subtypes: { enable_banking_account.id.to_s => "checking" }
         }

    linked_account = enable_banking_account.reload.account
    assert_not_nil linked_account
    assert_equal "AT611904300234573201", linked_account.iban # pipelock:ignore IBAN
  end
end
