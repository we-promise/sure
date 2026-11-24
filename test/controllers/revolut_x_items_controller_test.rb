# frozen_string_literal: true

require "test_helper"

class RevolutXItemsControllerTest < ActionDispatch::IntegrationTest
  API_KEY = "b2" * 32

  # The private key must never reach a browser, so every response in this file
  # is checked for it.
  %i[get post patch delete].each do |verb|
    define_method(verb) do |*args, **kwargs|
      super(*args, **kwargs).tap { assert_not_includes response.body, "PRIVATE KEY" }
    end
  end

  setup do
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)

    @family = families(:dylan_family)
    @existing_item = revolut_x_items(:one)
    @awaiting_item = revolut_x_items(:awaiting_api_key)
    @second_item = RevolutXItem.create!(family: @family, name: "Business", api_key: "c3" * 32)
  end

  test "create with a blank private key generates an Ed25519 key and starts no sync" do
    assert_difference "RevolutXItem.count", 1 do
      assert_no_difference "Sync.count" do
        post revolut_x_items_url, params: { revolut_x_item: { name: "Main", private_key: "" } }
      end
    end

    assert_redirected_to settings_providers_path
    item = @family.revolut_x_items.find_by!(name: "Main")
    assert_equal "ED25519", OpenSSL::PKey.read(item.private_key).oid
    assert_nil item.api_key
    assert_not item.credentials_configured?
    assert_equal "Revolut X", item.institution_name

    get connect_form_settings_providers_path(provider_key: "revolut_x")

    assert_response :success
    assert_includes response.body, "-----BEGIN PUBLIC KEY-----"
    assert_includes response.body, item.public_key_pem.lines.second.strip
    assert_select "form[action=?] input[type=password][name=?]", revolut_x_item_path(item), "revolut_x_item[api_key]"
  end

  test "create stores a supplied Ed25519 private key" do
    pem = OpenSSL::PKey.generate_key("ED25519").private_to_pem

    post revolut_x_items_url, params: { revolut_x_item: { name: "Own key", private_key: pem } }

    assert_redirected_to settings_providers_path
    assert_equal pem, @family.revolut_x_items.find_by!(name: "Own key").private_key
  end

  test "create rejects a non-Ed25519 private key with an error alert" do
    rsa_pem = OpenSSL::PKey::RSA.generate(2048).private_to_pem

    assert_no_difference "RevolutXItem.count" do
      post revolut_x_items_url,
           params: { revolut_x_item: { name: "RSA", private_key: rsa_pem } },
           as: :turbo_stream
    end

    assert_turbo_stream status: :unprocessable_entity, action: "replace", target: "revolut_x-providers-panel"
    assert_includes response.body, "#{I18n.t("ds.alert.variants.error")}:"
    assert_includes response.body, "Private key must be an Ed25519 private key in PEM format"
  end

  test "pasting a valid API key configures the connection and queues one sync" do
    assert_difference -> { Sync.where(syncable: @awaiting_item).count }, 1 do
      patch revolut_x_item_url(@awaiting_item), params: { revolut_x_item: { api_key: API_KEY } }, as: :turbo_stream
    end

    assert_turbo_stream action: "replace", target: "revolut_x-providers-panel"
    assert @awaiting_item.reload.credentials_configured?
    assert_equal API_KEY, @awaiting_item.api_key
  end

  test "an invalid API key shows an error alert and saves nothing" do
    private_key = @awaiting_item.private_key

    assert_no_difference "Sync.count" do
      patch revolut_x_item_url(@awaiting_item),
            params: { revolut_x_item: { name: "Renamed", api_key: "short" } },
            as: :turbo_stream
    end

    assert_turbo_stream status: :unprocessable_entity, action: "replace", target: "revolut_x-providers-panel"
    assert_includes response.body, "#{I18n.t("ds.alert.variants.error")}:"
    assert_includes response.body, "API key must be the 64-character key Revolut X shows"
    @awaiting_item.reload
    assert_nil @awaiting_item.api_key
    assert_equal "Revolut X Bot", @awaiting_item.name
    assert_equal private_key, @awaiting_item.private_key
  end

  test "blank key fields keep the stored keys and start no sync" do
    api_key = @second_item.api_key
    private_key = @second_item.private_key

    assert_no_difference "Sync.count" do
      patch revolut_x_item_url(@second_item), params: { revolut_x_item: { name: "Renamed", api_key: "", private_key: "" } }
    end

    assert_redirected_to settings_providers_path
    @second_item.reload
    assert_equal "Renamed", @second_item.name
    assert_equal api_key, @second_item.api_key
    assert_equal private_key, @second_item.private_key
  end

  test "update changes only the selected connection" do
    existing_key = @existing_item.api_key

    patch revolut_x_item_url(@second_item), params: { revolut_x_item: { api_key: API_KEY } }

    assert_equal existing_key, @existing_item.reload.api_key
    assert_equal API_KEY, @second_item.reload.api_key
  end

  test "the panel never prefills a key field" do
    get connect_form_settings_providers_path(provider_key: "revolut_x")

    assert_response :success
    assert_not_includes response.body, @existing_item.api_key
    assert_select "textarea[name='revolut_x_item[private_key]']" do |areas|
      areas.each { |area| assert_empty area.text.strip }
    end
  end

  test "select accounts requires an explicit connection when multiple items exist" do
    get select_accounts_revolut_x_items_url, params: { accountable_type: "Crypto" }

    assert_redirected_to settings_providers_path
    assert_equal "Choose a Revolut X connection in Provider Settings.", flash[:alert]
  end

  test "select accounts leaves the Add Account modal for Settings at the top level" do
    get select_accounts_revolut_x_items_url, params: { accountable_type: "Crypto" }, headers: { "Turbo-Frame" => "modal" }

    assert_response :success
    assert_select "turbo-frame#modal turbo-stream[action=redirect][target=?]", settings_providers_path
    assert_equal I18n.t("revolut_x_items.select_accounts.select_connection"), flash[:alert]
  end

  test "select accounts targets the selected item and ignores return paths" do
    [ nil, "///evil.example", "//evil.example/accounts" ].each do |return_to|
      get select_accounts_revolut_x_items_url, params: {
        revolut_x_item_id: @second_item.id, accountable_type: "Crypto", return_to: return_to
      }

      assert_redirected_to setup_accounts_revolut_x_item_path(@second_item)
    end
  end

  test "select accounts skips a connection still waiting for its API key" do
    get select_accounts_revolut_x_items_url, params: { revolut_x_item_id: @awaiting_item.id, accountable_type: "Crypto" }

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("revolut_x_items.select_accounts.no_credentials_configured"), flash[:alert]
  end

  test "link accounts requires an explicit connection when multiple items exist" do
    post link_accounts_revolut_x_items_url

    assert_redirected_to settings_providers_path
    assert_equal "Choose a Revolut X connection before linking accounts.", flash[:alert]
  end

  test "sync only queues a sync for the selected item" do
    assert_difference -> { Sync.where(syncable: @second_item).count }, 1 do
      assert_no_difference -> { Sync.where(syncable: @existing_item).count } do
        post sync_revolut_x_item_url(@second_item)
      end
    end

    assert_response :redirect
  end

  test "sync from the panel re-renders the panel in place" do
    post sync_revolut_x_item_url(@second_item, source: "panel"), as: :turbo_stream

    assert_turbo_stream action: "replace", target: "revolut_x-providers-panel"
    assert_includes response.body, I18n.t("settings.providers.sync_provider_in_progress")
    assert @second_item.reload.syncing?
  end

  test "setup accounts creates a linked crypto exchange account for the selected item only" do
    first_account = revolut_x_accounts(:one)
    second_account = @second_item.revolut_x_accounts.create!(
      name: "Business", account_id: "default", account_type: "exchange", currency: "USD", current_balance: 1000
    )
    RevolutXAccount::Processor.any_instance.stubs(:process).returns(nil)

    get setup_accounts_revolut_x_item_url(@second_item)
    assert_response :success
    assert_select "input[name='selected_accounts[]'][value=?]", second_account.id

    assert_difference [ "Account.count", "AccountProvider.count" ], 1 do
      post complete_account_setup_revolut_x_item_url(@second_item), params: { selected_accounts: [ second_account.id ] }
    end

    assert_redirected_to accounts_path
    assert_nil first_account.reload.current_account
    account = second_account.reload.current_account
    assert_equal "Crypto", account.accountable_type
    assert_equal "exchange", account.accountable.subtype
    assert_equal "Business", account.name
    assert_not @second_item.reload.pending_account_setup?
  end

  test "link existing account links a manual crypto exchange account" do
    manual_account = manual_crypto_exchange_account
    revolut_x_account = @second_item.revolut_x_accounts.create!(name: "Business", account_id: "default", account_type: "exchange", currency: "USD")

    assert_difference "AccountProvider.count", 1 do
      post link_existing_account_revolut_x_items_url, params: {
        revolut_x_item_id: @second_item.id, account_id: manual_account.id, revolut_x_account_id: revolut_x_account.id
      }
    end

    assert_redirected_to accounts_path
    assert_equal manual_account, revolut_x_account.reload.current_account
  end

  test "link existing account requires an explicit connection when multiple items exist" do
    account = manual_crypto_exchange_account

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_revolut_x_items_url, params: { account_id: account.id, revolut_x_account_id: "default" }
    end

    assert_redirected_to settings_providers_path
    assert_equal "Choose a Revolut X connection before linking accounts.", flash[:alert]
  end

  test "link existing account rejects non crypto accounts" do
    account = @family.accounts.create!(name: "Manual Checking", balance: 0, currency: "USD", accountable: Depository.new)
    revolut_x_account = @second_item.revolut_x_accounts.create!(name: "Business", account_id: "default", account_type: "exchange", currency: "USD")

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_revolut_x_items_url, params: {
        revolut_x_item_id: @second_item.id, account_id: account.id, revolut_x_account_id: revolut_x_account.id
      }
    end

    assert_redirected_to account_path(account)
  end

  test "link existing account rejects accounts with existing provider links" do
    account = manual_crypto_exchange_account
    AccountProvider.create!(account: account, provider: revolut_x_accounts(:one))
    revolut_x_account = @second_item.revolut_x_accounts.create!(name: "Business", account_id: "default", account_type: "exchange", currency: "USD")

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_revolut_x_items_url, params: {
        revolut_x_item_id: @second_item.id, account_id: account.id, revolut_x_account_id: revolut_x_account.id
      }
    end

    assert_redirected_to account_path(account)
  end

  test "link existing account rejects revolut x accounts already linked elsewhere" do
    linked_account = manual_crypto_exchange_account
    available_account = manual_crypto_exchange_account
    revolut_x_account = @second_item.revolut_x_accounts.create!(name: "Business", account_id: "default", account_type: "exchange", currency: "USD")
    AccountProvider.create!(account: linked_account, provider: revolut_x_account)

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_revolut_x_items_url, params: {
        revolut_x_item_id: @second_item.id, account_id: available_account.id, revolut_x_account_id: revolut_x_account.id
      }
    end

    assert_redirected_to account_path(available_account)
  end

  test "select existing account renders the selected item id" do
    account = manual_crypto_exchange_account
    @second_item.revolut_x_accounts.create!(name: "Business", account_id: "default", account_type: "exchange", currency: "USD")

    get select_existing_account_revolut_x_items_url, params: { revolut_x_item_id: @second_item.id, account_id: account.id }

    assert_response :success
    assert_includes response.body, %(name="revolut_x_item_id")
    assert_includes response.body, %(value="#{@second_item.id}")
  end

  test "destroy unlinks accounts and schedules deletion" do
    account = manual_crypto_exchange_account
    AccountProvider.create!(account: account, provider: revolut_x_accounts(:one))

    assert_difference "AccountProvider.count", -1 do
      delete revolut_x_item_url(@existing_item)
    end

    assert_redirected_to settings_providers_path
    assert @existing_item.reload.scheduled_for_deletion?
  end

  test "destroy does not schedule deletion when unlinking an account fails" do
    RevolutXItem.any_instance.stubs(:unlink_all!).returns([
      { provider_account_id: SecureRandom.uuid, name: "Revolut X", provider_link_ids: [], error: "boom" }
    ])
    RevolutXItem.any_instance.expects(:destroy_later).never

    delete revolut_x_item_url(@existing_item)

    assert_redirected_to settings_providers_path
    assert_equal I18n.t("revolut_x_items.destroy.unlink_failed"), flash[:alert]
    assert_not @existing_item.reload.scheduled_for_deletion?
  end

  test "link existing account rejects an account the admin cannot write" do
    account = account_the_admin_cannot_write
    revolut_x_account = @second_item.revolut_x_accounts.create!(name: "Business", account_id: "default", account_type: "exchange", currency: "USD")

    assert_no_difference "AccountProvider.count" do
      post link_existing_account_revolut_x_items_url, params: {
        revolut_x_item_id: @second_item.id, account_id: account.id, revolut_x_account_id: revolut_x_account.id
      }
    end

    assert_redirected_to accounts_path
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
    assert_nil revolut_x_account.reload.current_account
  end

  test "select existing account rejects an account the admin cannot write" do
    account = account_the_admin_cannot_write
    @second_item.revolut_x_accounts.create!(name: "Business", account_id: "default", account_type: "exchange", currency: "USD")

    get select_existing_account_revolut_x_items_url, params: { revolut_x_item_id: @second_item.id, account_id: account.id }

    assert_redirected_to accounts_path
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
  end

  test "setup accounts shows the balance in the family currency" do
    ensure_tailwind_build
    @family.update!(currency: "EUR")
    ExchangeRate.create!(from_currency: "USD", to_currency: "EUR", date: Date.current, rate: 0.9)
    @second_item.revolut_x_accounts.create!(name: "Business", account_id: "default", account_type: "exchange", currency: "USD", current_balance: 1_000)

    get setup_accounts_revolut_x_item_url(@second_item)

    assert_response :success
    assert_includes response.body, "€900.00"
  end

  test "members cannot use any action" do
    sign_in users(:family_member)
    account = manual_crypto_exchange_account

    requests = [
      -> { post revolut_x_items_url, params: { revolut_x_item: { name: "Member" } } },
      -> { patch revolut_x_item_url(@awaiting_item), params: { revolut_x_item: { api_key: API_KEY } } },
      -> { delete revolut_x_item_url(@second_item) },
      -> { post sync_revolut_x_item_url(@second_item) },
      -> { get setup_accounts_revolut_x_item_url(@second_item) },
      -> { post complete_account_setup_revolut_x_item_url(@second_item) },
      -> { get select_accounts_revolut_x_items_url(revolut_x_item_id: @second_item.id) },
      -> { post link_accounts_revolut_x_items_url(revolut_x_item_id: @second_item.id) },
      -> { get select_existing_account_revolut_x_items_url(revolut_x_item_id: @second_item.id, account_id: account.id) },
      -> { post link_existing_account_revolut_x_items_url(revolut_x_item_id: @second_item.id, account_id: account.id) }
    ]

    assert_no_difference [ "RevolutXItem.count", "Sync.count", "AccountProvider.count" ] do
      requests.each do |request|
        request.call
        assert_redirected_to accounts_path
        assert_equal I18n.t("shared.require_admin"), flash[:alert]
      end
    end
    assert_nil @awaiting_item.reload.api_key
    assert_not @second_item.reload.scheduled_for_deletion?
  end

  test "cannot access another family's item" do
    other_item = RevolutXItem.create!(family: families(:empty), name: "Other", api_key: API_KEY)

    get setup_accounts_revolut_x_item_url(other_item)

    assert_response :not_found
  end

  private

    def manual_crypto_exchange_account
      @family.accounts.create!(
        name: "Manual Crypto",
        balance: 0,
        currency: "USD",
        accountable: Crypto.create!(subtype: "exchange")
      )
    end

    # The admin only holds a read_only share on a co-member's account, short of
    # the :write (owner/full_control) the guard demands.
    def account_the_admin_cannot_write
      manual_crypto_exchange_account.tap do |account|
        account.account_shares.destroy_all
        account.update!(owner: users(:family_member))
        account.account_shares.create!(user: users(:family_admin), permission: "read_only")
      end
    end
end
