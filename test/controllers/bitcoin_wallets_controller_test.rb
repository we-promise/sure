require "test_helper"
require "support/bitcoin_wallet_test_helper"

class BitcoinWalletsControllerTest < ActionDispatch::IntegrationTest
  include BitcoinWalletTestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    @account = accounts(:crypto)
    sign_in @user
  end

  test "renders the source form behind the preview gate" do
    get new_account_bitcoin_wallet_path(@account)
    assert_response :success
    assert_select "input[name='source[address_or_key]'][type='text']"
    assert_select "input[name='source[receive_address]']"
  end

  test "does not expose the feature to users without preview access" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))
    get new_account_bitcoin_wallet_path(@account)
    assert_redirected_to root_path
  end

  test "creates a draft and queues discovery without changing account balances" do
    before = @account.balance
    assert_enqueued_with(job: SyncJob) do
      post account_bitcoin_wallet_path(@account), params: { source: { address_or_key: RECEIVE } }
    end
    assert_redirected_to account_bitcoin_wallet_path(@account)
    assert_equal before, @account.reload.balance
    refute @account.linked?
    assert @account.bitcoin_wallet_account.status_discovering?
  end

  test "rejects another family's account" do
    other = @account.dup
    other.family = families(:empty)
    other.owner = users(:empty)
    other.save!
    get new_account_bitcoin_wallet_path(other)
    assert_response :not_found
  end

  test "invalid source input does not leave a wallet behind" do
    assert_no_difference [ "BitcoinWalletAccount.count", "OnchainWalletItem.count", "Security.count" ] do
      post account_bitcoin_wallet_path(@account), params: { source: { address_or_key: "zpub-not-a-public-key", receive_address: RECEIVE } }
    end
    assert_response :unprocessable_entity
  end

  test "an invalid key keeps the submitted source and shows the error on the field" do
    post account_bitcoin_wallet_path(@account), params: { source: { address_or_key: "zpub-not-a-public-key",
      receive_address: RECEIVE, gap_limit: 50 } }
    assert_response :unprocessable_entity
    assert_select "input[name='source[address_or_key]'][value='zpub-not-a-public-key'][aria-invalid='true']"
    assert_select "[data-bitcoin-wallet-source-target='hdFields']:not([hidden])"
    assert_select "input[name='source[receive_address]'][value='#{RECEIVE}']"
    assert_select "input[name='source[gap_limit]'][value='50']"
    assert_select "p.text-destructive", text: I18n.t("bitcoin_wallets.errors.invalid_key")
  end

  test "a validation other than a malformed key keeps its own message" do
    post account_bitcoin_wallet_path(@account), params: { source: { address_or_key: ZPUB, receive_address: RECEIVE, gap_limit: 5 } }
    assert_response :unprocessable_entity
    assert_select "details[open] p.text-destructive", text: /20/
    assert_select "p.text-destructive", text: I18n.t("bitcoin_wallets.errors.invalid_key"), count: 0
  end

  test "a draft offers to cancel setup instead of disconnecting" do
    wallet = build_bitcoin_wallet(status: :preview, last_synced_at: Time.current)
    manual_bitcoin_source(wallet)
    get account_bitcoin_wallet_path(@account)
    assert_select "button", text: I18n.t("bitcoin_wallets.cancel")
    assert_select "button", text: I18n.t("bitcoin_wallets.stop_tracking"), count: 0
    delete account_bitcoin_wallet_path(@account)
    assert_redirected_to account_path(@account)
    assert_equal I18n.t("bitcoin_wallets.setup_cancelled"), flash[:notice]
  end

  test "shows discovery results without rendering the public key" do
    wallet = build_bitcoin_wallet(status: :preview, last_synced_at: Time.current, balance_sats: 1)
    wallet.bitcoin_wallet_sources.create!(kind: "bip84", receive_address: RECEIVE, extended_public_key: ZPUB)
    get account_bitcoin_wallet_path(@account)
    assert_response :success
    refute_includes response.body, ZPUB
    assert_select "button", text: I18n.t("bitcoin_wallets.start_tracking")
  end

  test "management actions require owner or full control within the family" do
    wallet = build_bitcoin_wallet(status: :preview, last_synced_at: Time.current)
    source = manual_bitcoin_source(wallet)
    Account.any_instance.stubs(:permission_for).returns(:view_only)
    assert_no_difference [ "BitcoinWalletAccount.count", "BitcoinWalletSource.count", "Entry.count" ] do
      get account_bitcoin_wallet_path(@account)
      assert_response :forbidden
      post connect_account_bitcoin_wallet_path(@account)
      assert_response :forbidden
      post add_source_account_bitcoin_wallet_path(@account), params: { source: { address_or_key: CHANGE } }
      assert_response :forbidden
      delete remove_source_account_bitcoin_wallet_path(@account), params: { source_id: source.id }
      assert_response :forbidden
      delete account_bitcoin_wallet_path(@account)
      assert_response :forbidden
    end
  end

  test "an existing connection can sync through the normal account route after preview is disabled" do
    wallet = build_bitcoin_wallet(status: :preview, last_synced_at: Time.current)
    manual_bitcoin_source(wallet)
    wallet.connect!
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))
    assert_equal sync_account_path(@account), @account.reload.providers.first.sync_path
    assert_enqueued_with(job: SyncJob) { post sync_account_path(@account) }
    assert_redirected_to account_path(@account)
  end

  test "an expired preview cannot connect and its button is hidden" do
    wallet = build_bitcoin_wallet(status: :preview, last_synced_at: 3.hours.ago)
    manual_bitcoin_source(wallet)
    get account_bitcoin_wallet_path(@account)
    assert_select "button", text: I18n.t("bitcoin_wallets.start_tracking"), count: 0
    post connect_account_bitcoin_wallet_path(@account)
    assert_redirected_to account_path(@account)
    assert_nil wallet.reload.account_provider
  end

  test "a family member who is not an admin cannot manage wallets" do
    member = users(:family_member)
    member.update!(preferences: member.preferences.merge("preview_features_enabled" => true))
    sign_in member
    get new_account_bitcoin_wallet_path(@account)
    assert_redirected_to accounts_path
  end

  test "adds a source and reads the wallet again" do
    wallet = build_bitcoin_wallet(status: :preview, last_synced_at: Time.current)
    manual_bitcoin_source(wallet)
    assert_difference "wallet.bitcoin_wallet_sources.count", 1 do
      assert_enqueued_with(job: SyncJob) do
        post add_source_account_bitcoin_wallet_path(@account), params: { source: { address_or_key: CHANGE } }
      end
    end
    assert_redirected_to account_bitcoin_wallet_path(@account)
    assert wallet.reload.status_discovering?
  end

  test "an invalid added source keeps the dialog open with its input" do
    wallet = build_bitcoin_wallet(status: :preview, last_synced_at: Time.current)
    manual_bitcoin_source(wallet)
    assert_no_difference "BitcoinWalletSource.count" do
      post add_source_account_bitcoin_wallet_path(@account), params: { source: { address_or_key: "not-an-address" } }
    end
    assert_response :unprocessable_entity
    assert_select "details[open] input[name='source[address_or_key]'][value='not-an-address']"
    assert_select "details[open] p.text-destructive", text: I18n.t("bitcoin_wallets.errors.invalid_address")
  end

  test "removing one of several sources rediscovers the rest" do
    wallet = build_bitcoin_wallet(status: :preview, last_synced_at: Time.current)
    manual_bitcoin_source(wallet)
    removed = manual_bitcoin_source(wallet, CHANGE)
    delete remove_source_account_bitcoin_wallet_path(@account), params: { source_id: removed.id }
    assert_redirected_to account_path(@account)
    assert_equal I18n.t("bitcoin_wallets.source_removed"), flash[:notice]
    assert_equal [ RECEIVE ], wallet.reload.bitcoin_wallet_sources.pluck(:receive_address)
    assert wallet.status_discovering?
  end

  test "removing the last source disconnects the wallet" do
    wallet = build_bitcoin_wallet(status: :preview, last_synced_at: Time.current)
    source = manual_bitcoin_source(wallet)
    wallet.connect!
    delete remove_source_account_bitcoin_wallet_path(@account), params: { source_id: source.id }
    assert_redirected_to account_path(@account)
    assert_equal I18n.t("bitcoin_wallets.disconnected"), flash[:notice]
    assert_nil @account.reload.bitcoin_wallet_account
  end

  test "sync queues a wallet read" do
    wallet = build_bitcoin_wallet(status: :preview, last_synced_at: Time.current)
    manual_bitcoin_source(wallet)
    assert_enqueued_with(job: SyncJob) { post sync_account_bitcoin_wallet_path(@account) }
    assert_redirected_to account_bitcoin_wallet_path(@account)
  end

  test "a source from another wallet cannot be removed" do
    wallet = build_bitcoin_wallet
    manual_bitcoin_source(wallet)
    other = @account.dup
    other.name = "Other crypto"
    other.save!
    other_wallet = build_bitcoin_wallet(account: other)
    source = manual_bitcoin_source(other_wallet, CHANGE)
    assert_no_difference "BitcoinWalletSource.count" do
      delete remove_source_account_bitcoin_wallet_path(@account), params: { source_id: source.id }
    end
    assert_response :not_found
  end

  test "the address disclosure is bounded without loading every discovered address" do
    wallet = build_bitcoin_wallet(status: :preview, last_synced_at: Time.current)
    manual_bitcoin_source(wallet)
    BitcoinWalletAddress.insert_all!(150.times.map do |index|
      { bitcoin_wallet_account_id: wallet.id, family_id: wallet.family.id, address: "public-fixture-#{index}" }
    end)
    get account_bitcoin_wallet_path(@account)
    assert_response :success
    assert_select "li", text: /^public-fixture-/, count: 100
    assert_select "p", text: I18n.t("bitcoin_wallets.address_count", count: 150)
  end
end
