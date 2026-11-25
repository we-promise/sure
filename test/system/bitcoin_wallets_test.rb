require "application_system_test_case"
require "support/bitcoin_wallet_test_helper"
require "support/provider_test_helper"
require "ostruct"

class BitcoinWalletsTest < ApplicationSystemTestCase
  include BitcoinWalletTestHelper
  include ProviderTestHelper

  setup do
    @user = users(:family_admin)
    @user.update!(preferences: @user.preferences.merge("preview_features_enabled" => true))
    @account = accounts(:crypto)
    @provider = FakeProvider.new
    @provider.fund(RECEIVE, 20_000_000)
    Provider::MempoolSpace.stubs(:new).returns(@provider)
    sign_in @user
  end

  test "a public address is previewed and connected to the existing account" do
    Onchain::SecurityResolver.enable_price_provider!
    Provider::BinancePublic.any_instance.stubs(:fetch_security_prices).returns(
      provider_success_response([ OpenStruct.new(date: Date.current, price: 10_000, currency: "USD") ])
    )

    visit account_path(@account)
    within "[data-testid='account-menu']" do
      find("button").click
      click_link I18n.t("bitcoin_wallets.connect_action")
    end
    assert_text I18n.t("bitcoin_wallets.new_title")
    fill_in I18n.t("bitcoin_wallets.key_label"), with: RECEIVE
    click_on I18n.t("bitcoin_wallets.discover")
    assert_text I18n.t("bitcoin_wallets.discovering_title")
    wallet = @account.reload.bitcoin_wallet_account
    SyncJob.perform_now(wallet.syncs.ordered.first)
    assert_text "0.2 BTC"
    within "turbo-frame[id^='status_']" do
      assert_text Money.new(2_000, "USD").format
    end
    assert_text I18n.t("bitcoin_wallets.start_tracking")
    page.save_screenshot(Rails.root.join("tmp", "bitcoin-wallet-preview.png"))
    click_on I18n.t("bitcoin_wallets.start_tracking")
    assert_current_path account_path(@account)
    assert_text I18n.t("bitcoin_wallets.header_badge")
    assert @account.reload.bitcoin_wallet_account.account_provider
    assert_equal BigDecimal("0.2"), @account.reload.current_holdings.find_by!(security: wallet.security).qty
    visit account_bitcoin_wallet_path(@account)
    assert_selector "summary", text: /#{Regexp.escape(I18n.t("bitcoin_wallets.details"))}/i
    page.save_screenshot(Rails.root.join("tmp", "bitcoin-wallet-connected.png"))
  end

  test "HD fields are conditional and the connection dialog fits a narrow screen" do
    page.current_window.resize_to(360, 800)
    visit new_account_bitcoin_wallet_path(@account)
    assert_no_selector "input[name='source[receive_address]']"
    fill_in I18n.t("bitcoin_wallets.key_label"), with: ZPUB
    assert_selector "input[name='source[receive_address]']"
    find("summary", text: /#{Regexp.escape(I18n.t("bitcoin_wallets.advanced"))}/i).click
    assert_selector "input[name='source[gap_limit]']"
    assert page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth")
  ensure
    page.current_window.resize_to(1400, 900)
  end

  test "a cleared invalid key keeps its error and verification field visible" do
    visit new_account_bitcoin_wallet_path(@account)
    fill_in I18n.t("bitcoin_wallets.key_label"), with: "zpub.bad"
    fill_in I18n.t("bitcoin_wallets.verification_address"), with: RECEIVE
    click_on I18n.t("bitcoin_wallets.discover")

    assert_text I18n.t("bitcoin_wallets.errors.invalid_key")
    assert_field I18n.t("bitcoin_wallets.key_label"), with: ""
    assert_field I18n.t("bitcoin_wallets.verification_address"), with: RECEIVE
  end

  test "status polling refreshes addresses and keeps the source field focused with its typed value" do
    wallet = build_bitcoin_wallet(status: :discovering)
    manual_bitcoin_source(wallet)
    sync = wallet.sync_later
    visit account_bitcoin_wallet_path(@account)
    find("summary", text: /#{Regexp.escape(I18n.t("bitcoin_wallets.details"))}/i).click
    assert_text I18n.t("bitcoin_wallets.address_count", count: 0)
    fill_in I18n.t("bitcoin_wallets.key_label"), with: CHANGE
    wallet.bitcoin_wallet_addresses.create!(family: wallet.family, address: RECEIVE, used: true)
    wallet.update!(status: :preview, balance_sats: 20_000_000, last_synced_at: Time.current)
    sync.update!(status: "completed")
    assert_text I18n.t("bitcoin_wallets.start_tracking")
    within "turbo-frame[id^='addresses_']" do
      assert_text I18n.t("bitcoin_wallets.address_count", count: 1)
      assert_selector "li", exact_text: RECEIVE
    end
    assert_field I18n.t("bitcoin_wallets.key_label"), with: CHANGE
    assert_selector "input[name='source[address_or_key]']:focus"
  end

  test "a connected wallet retains manual activity and can disconnect" do
    wallet = build_bitcoin_wallet(status: :preview, last_synced_at: Time.current, balance_sats: 20_000_000)
    manual_bitcoin_source(wallet)
    wallet.connect!
    visit account_path(@account)
    assert_selector "[data-testid='activity-menu'] button"
    visit account_bitcoin_wallet_path(@account)
    click_on I18n.t("bitcoin_wallets.stop_tracking")
    within "dialog[open]", text: I18n.t("bitcoin_wallets.disconnect_confirm") do
      click_button "Confirm"
    end
    assert_current_path account_path(@account)
    assert_selector "[data-testid='activity-menu'] button"
    assert_nil @account.reload.bitcoin_wallet_account
    assert @account.reload.manual_accounting?
    assert_equal BigDecimal("0.2"), @account.current_holdings.find_by!(security: wallet.security).qty
  end
end
