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
    assert_select "input[name='source[extended_public_key]'][type='password']"
    assert_select "input[name='source[receive_address]']"
  end

  test "does not expose the feature to users without preview access" do
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => false))
    get new_account_bitcoin_wallet_path(@account)
    assert_redirected_to root_path
  end

  test "creates a draft and queues discovery without changing account balances" do
    before = @account.balance
    assert_enqueued_with(job: BitcoinWalletSyncJob) do
      post account_bitcoin_wallet_path(@account), params: { source: { kind: "address", receive_address: RECEIVE } }
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
      post account_bitcoin_wallet_path(@account), params: { source: { kind: "bip84", receive_address: RECEIVE, extended_public_key: "not-a-public-key" } }
    end
    assert_response :unprocessable_entity
  end

  test "shows discovery results without rendering the public key" do
    wallet = build_bitcoin_wallet(status: :preview, last_synced_at: Time.current, balance_sats: 1)
    wallet.bitcoin_wallet_sources.create!(kind: "bip84", receive_address: RECEIVE, extended_public_key: ZPUB)
    get account_bitcoin_wallet_path(@account)
    assert_response :success
    refute_includes response.body, ZPUB
    assert_select "button", text: I18n.t("bitcoin_wallets.connect")
  end
end
