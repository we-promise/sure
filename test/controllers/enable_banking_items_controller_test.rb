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

  # --- IBAN-based dedup tests for complete_account_setup ---

  test "complete_account_setup deduplicates by IBAN when another item already linked the same IBAN" do
    shared_iban = "DE89370400440532013000"

    # Other item in same family that already set up a shared joint account
    other_item = @family.enable_banking_items.create!(
      name: "Spouse Connection",
      country_code: "DE",
      application_id: "test_app_id",
      client_certificate: OpenSSL::PKey::RSA.new(2048).to_pem,
      pending_account_setup: true
    )
    other_eba = other_item.enable_banking_accounts.create!(
      uid: "uid-other",
      name: "Joint Account",
      currency: "EUR",
      iban: shared_iban,
      current_balance: 5000
    )
    existing_account = Account.create_from_enable_banking_account(other_eba, "Depository", "checking")
    AccountProvider.create!(account: existing_account, provider: other_eba)

    # The current item also has an account with the same IBAN
    current_eba = @item.enable_banking_accounts.create!(
      uid: "uid-current",
      name: "Joint Account",
      currency: "EUR",
      iban: shared_iban,
      current_balance: 5000
    )

    assert_difference -> { Account.count } => 0,
                      -> { AccountProvider.count } => 1 do
      post complete_account_setup_enable_banking_item_url(@item),
           params: { account_types: { current_eba.id => "Depository" },
                     account_subtypes: { current_eba.id => "checking" } }
    end

    assert_redirected_to accounts_path
    assert current_eba.reload.account_provider.present?,
      "Expected EnableBankingAccount to be linked via AccountProvider"
    assert_equal existing_account.id, current_eba.account_provider.account_id,
      "Expected duplicate IBAN to link to the existing family Account"
  end

  test "complete_account_setup creates new account when IBAN is blank" do
    eba = @item.enable_banking_accounts.create!(
      uid: "uid-no-iban",
      name: "Account Without IBAN",
      currency: "EUR",
      iban: nil,
      current_balance: 1000
    )

    assert_difference -> { Account.count } => 1,
                      -> { AccountProvider.count } => 1 do
      post complete_account_setup_enable_banking_item_url(@item),
           params: { account_types: { eba.id => "Depository" },
                     account_subtypes: { eba.id => "checking" } }
    end

    assert_redirected_to accounts_path
    assert eba.reload.account_provider.present?
  end

  test "complete_account_setup creates new account when IBAN differs across items" do
    other_iban = "DE89370400440532013000"
    current_iban = "DE02700100800030874808"

    # Other item already set up an account with a different IBAN
    other_item = @family.enable_banking_items.create!(
      name: "Spouse Connection",
      country_code: "DE",
      application_id: "test_app_id",
      client_certificate: OpenSSL::PKey::RSA.new(2048).to_pem,
      pending_account_setup: true
    )
    other_eba = other_item.enable_banking_accounts.create!(
      uid: "uid-other",
      name: "Personal Checking",
      currency: "EUR",
      iban: other_iban,
      current_balance: 3000
    )
    existing_account = Account.create_from_enable_banking_account(other_eba, "Depository", "checking")
    AccountProvider.create!(account: existing_account, provider: other_eba)

    # Current item has a DIFFERENT IBAN
    current_eba = @item.enable_banking_accounts.create!(
      uid: "uid-current",
      name: "My Personal Checking",
      currency: "EUR",
      iban: current_iban,
      current_balance: 3000
    )

    assert_difference -> { Account.count } => 1,
                      -> { AccountProvider.count } => 1 do
      post complete_account_setup_enable_banking_item_url(@item),
           params: { account_types: { current_eba.id => "Depository" },
                     account_subtypes: { current_eba.id => "checking" } }
    end

    assert_not_equal existing_account.id, current_eba.reload.account_provider.account_id,
      "Expected different IBANs to produce separate Accounts"
  end

  test "complete_account_setup handles mixed dedup and non-dedup accounts in one request" do
    shared_iban = "DE89370400440532013000"

    # Other item already linked the shared account
    other_item = @family.enable_banking_items.create!(
      name: "Spouse Connection",
      country_code: "DE",
      application_id: "test_app_id",
      client_certificate: OpenSSL::PKey::RSA.new(2048).to_pem,
      pending_account_setup: true
    )
    other_eba = other_item.enable_banking_accounts.create!(
      uid: "uid-other",
      name: "Joint Account",
      currency: "EUR",
      iban: shared_iban,
      current_balance: 5000
    )
    existing_account = Account.create_from_enable_banking_account(other_eba, "Depository", "checking")
    AccountProvider.create!(account: existing_account, provider: other_eba)

    # Current item: a shared IBAN and a personal one
    shared_eba = @item.enable_banking_accounts.create!(
      uid: "uid-shared",
      name: "Joint Account",
      currency: "EUR",
      iban: shared_iban,
      current_balance: 5000
    )
    personal_eba = @item.enable_banking_accounts.create!(
      uid: "uid-personal",
      name: "Personal Savings",
      currency: "EUR",
      iban: "DE02700100800030874808",
      current_balance: 2000
    )

    assert_difference -> { Account.count } => 1,  # only personal is new
                      -> { AccountProvider.count } => 2 do
      post complete_account_setup_enable_banking_item_url(@item),
           params: {
             account_types: {
               shared_eba.id => "Depository",
               personal_eba.id => "Depository"
             },
             account_subtypes: {
               shared_eba.id => "checking",
               personal_eba.id => "savings"
             }
           }
    end

    assert_redirected_to accounts_path
    assert_equal existing_account.id, shared_eba.reload.account_provider.account_id,
      "Expected shared IBAN to dedup to existing Account"
    assert personal_eba.reload.account_provider.present?,
      "Expected personal account to be linked"
    assert_not_equal existing_account.id, personal_eba.account_provider.account_id,
      "Expected personal account to have its own Account"
  end

  test "find_existing_family_account_for_iban ignores unlinked EnableBankingAccounts" do
    shared_iban = "DE89370400440532013000"

    # Other item has an EnableBankingAccount with the same IBAN but it's NOT linked yet
    other_item = @family.enable_banking_items.create!(
      name: "Spouse Connection",
      country_code: "DE",
      application_id: "test_app_id",
      client_certificate: OpenSSL::PKey::RSA.new(2048).to_pem,
      pending_account_setup: true
    )
    other_eba = other_item.enable_banking_accounts.create!(
      uid: "uid-other",
      name: "Joint Account",
      currency: "EUR",
      iban: shared_iban,
      current_balance: 5000
    )
    # Deliberately NOT creating an Account or AccountProvider for other_eba

    # Current item also has the same IBAN
    current_eba = @item.enable_banking_accounts.create!(
      uid: "uid-current",
      name: "Joint Account",
      currency: "EUR",
      iban: shared_iban,
      current_balance: 5000
    )

    # Should create a new Account since other_eba isn't linked yet
    assert_difference -> { Account.count } => 1,
                      -> { AccountProvider.count } => 1 do
      post complete_account_setup_enable_banking_item_url(@item),
           params: { account_types: { current_eba.id => "Depository" },
                     account_subtypes: { current_eba.id => "checking" } }
    end

    assert_redirected_to accounts_path
    assert current_eba.reload.account_provider.present?
  end

  test "setup_accounts keeps blank IBAN accounts visible when linked_ibans exist" do
    # Create a linked account on another item to populate linked_ibans
    other_item = @family.enable_banking_items.create!(
      name: "Spouse Connection",
      country_code: "DE",
      application_id: "test_app_id",
      client_certificate: OpenSSL::PKey::RSA.new(2048).to_pem
    )
    other_eba = other_item.enable_banking_accounts.create!(
      uid: "uid-linked",
      name: "Linked Account",
      currency: "EUR",
      iban: "DE89370400440532013000",
      current_balance: 5000
    )
    linked_account = Account.create_from_enable_banking_account(other_eba, "Depository", "checking")
    AccountProvider.create!(account: linked_account, provider: other_eba)

    # Current item: one account with nil IBAN, one with a different IBAN
    nil_iban_eba = @item.enable_banking_accounts.create!(
      uid: "uid-nil-iban",
      name: "No IBAN Account",
      currency: "EUR",
      iban: nil,
      current_balance: 1000
    )
    unique_iban_eba = @item.enable_banking_accounts.create!(
      uid: "uid-unique",
      name: "Unique IBAN Account",
      currency: "EUR",
      iban: "DE02700100800030874808",
      current_balance: 2000
    )

    get setup_accounts_enable_banking_item_url(@item)

    assert_response :success
    # Both accounts should be visible in the rendered modal
    assert_includes @response.body, "No IBAN Account"
    assert_includes @response.body, "Unique IBAN Account"
  end
end
