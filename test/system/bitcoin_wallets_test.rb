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
    SyncJob.perform_now(wallet.syncs.ordered.first)
    assert_text "0.2 BTC"
    assert_text I18n.t("bitcoin_wallets.connect")
    page.save_screenshot(Rails.root.join("tmp", "bitcoin-wallet-preview.png"))
    click_on I18n.t("bitcoin_wallets.connect")
    assert_current_path account_path(@account)
    assert @account.reload.bitcoin_wallet_account.account_provider
    assert_equal BigDecimal("0.2"), @account.reload.current_holdings.find_by!(security: @security).qty
    visit account_bitcoin_wallet_path(@account)
    assert_selector "summary", text: /#{Regexp.escape(I18n.t("bitcoin_wallets.add_source"))}/i
    page.save_screenshot(Rails.root.join("tmp", "bitcoin-wallet-connected.png"))
  end

  test "HD fields are conditional and the connection dialog fits a narrow screen" do
    page.current_window.resize_to(360, 800)
    visit new_account_bitcoin_wallet_path(@account)
    assert_no_selector "input[name='source[extended_public_key]']"
    select I18n.t("bitcoin_wallets.bip84"), from: I18n.t("bitcoin_wallets.source_kind")
    assert_selector "input[name='source[extended_public_key]']"
    assert_selector "input[name='source[gap_limit]']"
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")
  ensure
    page.current_window.resize_to(1400, 900)
  end

  test "a connected wallet retains manual activity and can disconnect" do
    wallet = build_bitcoin_wallet(status: :preview, last_synced_at: Time.current, balance_sats: 20_000_000)
    manual_bitcoin_source(wallet)
    wallet.connect!
    visit account_path(@account)
    assert_selector "[data-testid='activity-menu'] button"
    visit account_bitcoin_wallet_path(@account)
    click_on I18n.t("bitcoin_wallets.disconnect")
    within "dialog[open]", text: I18n.t("bitcoin_wallets.disconnect_confirm") do
      click_button "Confirm"
    end
    assert_current_path account_path(@account)
    assert_selector "[data-testid='activity-menu'] button"
    assert_nil @account.reload.bitcoin_wallet_account
    assert @account.reload.manual_accounting?
    assert_equal BigDecimal("0.2"), @account.current_holdings.find_by!(security: @security).qty
  end
end
