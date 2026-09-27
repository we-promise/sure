require "application_system_test_case"
require "support/bitcoin_wallet_test_helper"

class BitcoinWalletsTest < ApplicationSystemTestCase
  include BitcoinWalletTestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    @account = accounts(:crypto)
    @security = Security.find_or_create_by!(ticker: "CRYPTO:BTC") { |row| row.name = "Bitcoin" }
    @security.prices.find_or_initialize_by(date: Date.current).update!(price: 10_000, currency: "USD")
    @provider = FakeProvider.new
    @provider.fund(RECEIVE, 20_000_000)
    Provider::MempoolSpace.stubs(:new).returns(@provider)
    sign_in @user
  end

  test "a public address is previewed and connected to the existing account" do
    visit new_account_bitcoin_wallet_path(@account)
    assert_text I18n.t("bitcoin_wallets.title")
    fill_in I18n.t("bitcoin_wallets.receive_address"), with: RECEIVE
    click_on I18n.t("bitcoin_wallets.discover")
    assert_text I18n.t("bitcoin_wallets.discovering")
    wallet = @account.reload.bitcoin_wallet_account
    BitcoinWalletAccount::Syncer.new(wallet, provider: @provider).perform
    click_on I18n.t("bitcoin_wallets.refresh")
    assert_text "0.2 BTC"
    assert_text I18n.t("bitcoin_wallets.connect")
    page.save_screenshot(Rails.root.join("tmp", "bitcoin-wallet-preview.png"))
    click_on I18n.t("bitcoin_wallets.connect")
    assert_text I18n.t("bitcoin_wallets.connected")
    assert_equal BigDecimal("0.2"), @account.reload.current_holdings.find_by!(security: @security).qty
    visit account_bitcoin_wallet_path(@account)
    assert_selector "summary", text: /#{Regexp.escape(I18n.t("bitcoin_wallets.add_source"))}/i
    page.save_screenshot(Rails.root.join("tmp", "bitcoin-wallet-connected.png"))
  end
end
