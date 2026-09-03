# frozen_string_literal: true

require "test_helper"

class OnchainWalletItemsLocalizationTest < ActionDispatch::IntegrationTest
  include OnchainTestHelper

  MODAL_HEADERS = { "Turbo-Frame" => "modal" }.freeze

  TRANSLATED_SCOPES = %w[
    onchain_wallet_items
    settings.providers.onchain_wallet_panel
  ].freeze

  TRANSLATED_KEYS = %w[
    settings.providers.taglines.onchain_wallet
  ].freeze

  setup do
    sign_in users(:family_admin)
    register_fake_chain!
  end

  teardown do
    unregister_fake_chain!
  end

  test "the Onchain wallet slices resolve directly in German" do
    translated_keys.each do |key|
      assert I18n.exists?(key, :de, fallback: false), "de is missing #{key}"
    end
  end

  test "German translations preserve interpolation and pluralization contracts" do
    address = OnchainTestHelper::FAKE_ADDRESS

    assert_equal address,
                 I18n.t("onchain_wallet_items.choose_chain.subtitle", locale: :de, fallback: false, address: address)
    assert_equal "Fake Chain · #{address}",
                 I18n.t("onchain_wallet_items.token_review.subtitle", locale: :de, fallback: false,
                                                                           chain: "Fake Chain", address: address)
    exchange_rate_body = I18n.t("onchain_wallet_items.price_provider_warning.exchange_rate_body",
                                locale: :de, fallback: false, currency: "EUR")
    %w[USD EUR EXCHANGE_RATE_PROVIDER Frankfurter API-Schlüssel].each do |technical_term|
      assert_match technical_term, exchange_rate_body
    end
    tagline = I18n.t("settings.providers.taglines.onchain_wallet", locale: :de, fallback: false)
    %w[Bitcoin EVM Solana].each { |brand_or_network| assert_match brand_or_network, tagline }
    assert_match "USDC",
                 I18n.t("onchain_wallet_items.link_wallet.errors.some_failed", locale: :de,
                                                                                 fallback: false, assets: "USDC")
    assert_equal "1 Vermögenswert dieser Wallet wird verfolgt.",
                 I18n.t("onchain_wallet_items.link_wallet.success", locale: :de, fallback: false, count: 1)
    assert_equal "2 Vermögenswerte dieser Wallet werden verfolgt.",
                 I18n.t("onchain_wallet_items.link_wallet.success", locale: :de, fallback: false, count: 2)
    assert_match "25", I18n.t("onchain_wallet_items.token_review_form.assets_truncated",
                              locale: :de, fallback: false, count: 25)
    assert_equal "USDC wird nicht mehr verfolgt. Das Konto und der Verlauf bleiben erhalten.",
                 I18n.t("onchain_wallet_items.disconnect_asset.success", locale: :de,
                                                                 fallback: false, symbol: "USDC")
    assert_equal "1 Vermögenswert an dieser Adresse wird nicht mehr verfolgt.",
                 I18n.t("onchain_wallet_items.disconnect_wallet.success", locale: :de,
                                                                  fallback: false, count: 1)
    assert_equal "2 Vermögenswerte an dieser Adresse werden nicht mehr verfolgt.",
                 I18n.t("onchain_wallet_items.disconnect_wallet.success", locale: :de,
                                                                  fallback: false, count: 2)
    assert_match "USDC",
                 I18n.t("onchain_wallet_items.manage.disconnect_asset_confirm", locale: :de,
                                                                                 fallback: false, symbol: "USDC")
    assert_equal "Verfolgte Vermögenswerte aktualisiert (2 hinzugefügt, 1 entfernt).",
                 I18n.t("onchain_wallet_items.update_tokens.success", locale: :de,
                                                                           fallback: false, created: 2, removed: 1)
    assert_equal "Vor 5 Minuten synchronisiert",
                 I18n.t("onchain_wallet_items.wallet_card.status", locale: :de,
                                                                       fallback: false, timestamp: "5 Minuten")
  end

  test "the German management page renders tracked wallet actions" do
    item = create_onchain_wallet_item(family: users(:family_admin).family)
    create_onchain_wallet_account(item: item)
    create_onchain_wallet_account(item: item, asset: fake_token_asset(symbol: "USDC", contract: "0xusdc"))

    get manage_onchain_wallet_item_url(item, locale: :de), headers: MODAL_HEADERS

    assert_response :success
    assert_match "Selbstverwahrte Wallets verwalten", response.body
    assert_match "Vermögenswerte verwalten", response.body
    assert_match "Wallet trennen", response.body
    assert_match "Nicht mehr verfolgen", response.body
    assert_match OnchainTestHelper::FAKE_ADDRESS, response.body
    assert_match "USDC", response.body
    assert_no_match "Manage self-custody wallets", response.body
    assert_no_match "Disconnect wallet", response.body
  end

  test "the German settings panel renders management and advanced actions" do
    item = create_onchain_wallet_item(family: users(:family_admin).family)
    create_onchain_wallet_account(item: item)

    get connect_form_settings_providers_path(provider_key: "onchain_wallet", locale: :de)

    assert_response :success
    assert_match "Wallets verwalten", response.body
    assert_match "Erweitert", response.body
    assert_match "Etherscan-API-Schlüssel (optional)", response.body
    assert_match "Übertragungen vor diesem Datum ignorieren", response.body
    assert_match "Alle Wallets trennen", response.body
    assert_no_match "Manage wallets", response.body
    assert_no_match "Disconnect all wallets", response.body
  end

  test "the German add-wallet form renders its security guidance" do
    get new_wallet_onchain_wallet_items_url(locale: :de), headers: MODAL_HEADERS

    assert_response :success
    assert_match "Selbstverwahrte Wallet hinzufügen", response.body
    assert_match "Nur Lesezugriff, keine Schlüssel erforderlich", response.body
    assert_match "Mit diesen Daten lassen sich keine Vermögenswerte übertragen.", response.body
    assert_match "Gib niemals eine Seed-Phrase oder einen Private Key ein.", response.body
    assert_match "Bitcoin wird jeweils über eine einzelne Adresse verfolgt.", response.body
  end

  test "the German token review renders selection guidance" do
    stub_fake_snapshot(
      OnchainTestHelper::FAKE_ADDRESS,
      Onchain::Snapshot.new(
        assets: [
          fake_native_asset(quantity: 2),
          fake_token_asset(symbol: "USDC", contract: "0xusdc", quantity: 10, notable: false),
          fake_token_asset(symbol: "Visit site to claim", contract: "0xspam", quantity: 1, notable: false)
        ],
        movements: []
      )
    )

    post preview_wallet_onchain_wallet_items_url(locale: :de),
         params: {
           address: OnchainTestHelper::FAKE_ADDRESS,
           chain: OnchainTestHelper::FAKE_CHAIN
         },
         headers: MODAL_HEADERS

    assert_response :success
    assert_match "Vermögenswerte zum Verfolgen auswählen", response.body
    assert_match "Wallets erhalten Spam-Airdrops", response.body
    assert_match "Kein Preis verfügbar; wird nur anhand der Menge verfolgt", response.body
    assert_match "USDC", response.body
  end

  test "the German account method selector localizes the Onchain entry" do
    get new_crypto_url(locale: :de, step: "method_select"), headers: MODAL_HEADERS

    assert_response :success
    assert_match "Selbstverwahrte Wallet", response.body
    assert_no_match "Self-custody wallet", response.body
  end

  test "a German recovery state hides the external provider error" do
    external_error = "external explorer exposed a private diagnostic"
    OnchainTestHelper::FakeAdapter.error = StandardError.new(external_error)

    assert_difference "DebugLogEntry.count", 1 do
      post preview_wallet_onchain_wallet_items_url(locale: :de),
           params: {
             address: OnchainTestHelper::FAKE_ADDRESS,
             chain: OnchainTestHelper::FAKE_CHAIN
           },
           headers: MODAL_HEADERS
    end

    assert_response :unprocessable_entity
    assert_match "Beim Lesen dieser Wallet ist etwas schiefgelaufen.", response.body
    assert_no_match external_error, response.body
  end

  test "representative English output remains unchanged" do
    I18n.with_locale(:en) do
      assert_equal "Add a self-custody wallet", I18n.t("onchain_wallet_items.new_wallet.title", fallback: false)
      assert_equal "Read-only, no keys required",
                   I18n.t("settings.providers.onchain_wallet_panel.keyless_title", fallback: false)
      assert_equal "Only public chain data is read. Never enter a seed phrase or private key.",
                   I18n.t("onchain_wallet_items.new_wallet.read_only_note", fallback: false)
      assert_equal "Self-custody wallet",
                   I18n.t("onchain_wallet_items.provider_connection.name", fallback: false)
      assert_equal "Manage self-custody wallets",
                   I18n.t("onchain_wallet_items.manage.title", fallback: false)
      assert_equal "Stopped tracking 2 assets at that address.",
                   I18n.t("onchain_wallet_items.disconnect_wallet.success", fallback: false, count: 2)
      assert_equal "Etherscan API key (optional)",
                   I18n.t("settings.providers.onchain_wallet_panel.etherscan_api_key_label", fallback: false)
    end

    get new_wallet_onchain_wallet_items_url(locale: :en), headers: MODAL_HEADERS

    assert_response :success
    assert_match "Add a self-custody wallet", response.body
    assert_match "Read-only, no keys required", response.body
    assert_match "Never enter a seed phrase or private key.", response.body
  end

  private
    def translated_keys
      scoped_keys = TRANSLATED_SCOPES.flat_map do |scope|
        translations = I18n.t(scope, locale: :en, fallback: false, default: nil)
        assert_kind_of Hash, translations, "#{scope} must remain a translation subtree"

        flatten_keys(translations).map { |key| "#{scope}.#{key}" }
      end

      scoped_keys + TRANSLATED_KEYS
    end

    def flatten_keys(translations, prefix = nil)
      translations.flat_map do |key, value|
        path = [ prefix, key ].compact.join(".")
        value.is_a?(Hash) ? flatten_keys(value, path) : path
      end
    end
end
