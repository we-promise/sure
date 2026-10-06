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

  test "link_existing_account propagates the discovered iban to the manual account" do
    @item.update!(session_id: "test_session")
    enable_banking_account = @item.enable_banking_accounts.create!(
      uid: "acct_uid_3",
      name: "Checking",
      currency: "EUR",
      iban: "DE89370400440532013000" # pipelock:ignore IBAN
    )
    manual_account = @family.accounts.create!(name: "Manual Checking", balance: 0, currency: "EUR", accountable: Depository.new)

    post link_existing_account_enable_banking_items_url,
         params: { account_id: manual_account.id, enable_banking_account_id: enable_banking_account.id }

    assert_equal "DE89370400440532013000", manual_account.reload.iban # pipelock:ignore IBAN
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
