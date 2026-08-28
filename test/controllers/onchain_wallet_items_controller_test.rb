# frozen_string_literal: true

require "test_helper"

class OnchainWalletItemsControllerTest < ActionDispatch::IntegrationTest
  include OnchainTestHelper

  setup do
    sign_in users(:family_admin)
    SyncJob.stubs(:perform_later)
    register_fake_chain!
    @family = families(:dylan_family)
  end

  teardown do
    unregister_fake_chain!
  end

  test "new_wallet renders the address form with the read-only and Bitcoin notes" do
    get new_wallet_onchain_wallet_items_url

    assert_response :success
    assert_match I18n.t("onchain_wallet_items.new_wallet.bitcoin_single_address_note"), response.body
    # "Can Sure spend my coins?" is asked while pasting an address, not while
    # reading a settings page for the third time.
    assert_match I18n.t("settings.providers.onchain_wallet_panel.keyless_title"), response.body
    assert_match I18n.t("onchain_wallet_items.new_wallet.read_only_note"), response.body
  end

  test "the settings panel renders before anything is linked" do
    get connect_form_settings_providers_path(provider_key: "onchain_wallet")

    assert_response :success
    assert_select "a[href=?]", new_wallet_onchain_wallet_items_path
  end

  test "the settings panel renders the tracked wallets and the connection settings" do
    item = create_onchain_wallet_item(family: @family)
    create_onchain_wallet_account(item: item)

    get connect_form_settings_providers_path(provider_key: "onchain_wallet")

    assert_response :success
    assert_match OnchainTestHelper::FAKE_ADDRESS.first(6), response.body
    assert_match I18n.t("settings.providers.onchain_wallet_panel.etherscan_api_key_label"), response.body
    assert_match I18n.t("settings.providers.onchain_wallet_panel.sync_start_date_label"), response.body
    assert_select "form[action=?]", sync_onchain_wallet_item_path(item)
    assert_select "a[href=?]", manage_onchain_wallet_item_path(item)
  end

  test "the price provider warning appears only when no crypto provider is enabled" do
    get new_wallet_onchain_wallet_items_url
    assert_match I18n.t("onchain_wallet_items.price_provider_warning.title"), response.body

    Setting.stubs(:enabled_securities_providers).returns([ Onchain::SecurityResolver::PRICE_PROVIDER ])

    get new_wallet_onchain_wallet_items_url
    assert_no_match I18n.t("onchain_wallet_items.price_provider_warning.title"), response.body
  end

  test "a non-USD family is warned that nothing can convert USD prices" do
    Setting.stubs(:enabled_securities_providers).returns([ Onchain::SecurityResolver::PRICE_PROVIDER ])
    ExchangeRate.stubs(:provider).returns(nil)
    @family.update!(currency: "EUR")

    get new_wallet_onchain_wallet_items_url

    assert_match I18n.t("onchain_wallet_items.price_provider_warning.exchange_rate_title"), response.body
    assert_no_match I18n.t("onchain_wallet_items.price_provider_warning.title"), response.body
  end

  test "a USD family with crypto prices on sees no pricing warning at all" do
    Setting.stubs(:enabled_securities_providers).returns([ Onchain::SecurityResolver::PRICE_PROVIDER ])

    get new_wallet_onchain_wallet_items_url

    assert_no_match I18n.t("onchain_wallet_items.price_provider_warning.title"), response.body
    assert_no_match I18n.t("onchain_wallet_items.price_provider_warning.exchange_rate_title"), response.body
  end

  test "the warning offers a one-click fix on a self-hosted instance" do
    Rails.configuration.stubs(:app_mode).returns(ActiveSupport::StringInquirer.new("self_hosted"))

    get new_wallet_onchain_wallet_items_url

    assert_select "form[action=?]", enable_crypto_prices_onchain_wallet_items_path
  end

  test "enable_crypto_prices adds the crypto provider without disabling the others" do
    Rails.configuration.stubs(:app_mode).returns(ActiveSupport::StringInquirer.new("self_hosted"))
    Setting.securities_providers = "twelve_data"

    post enable_crypto_prices_onchain_wallet_items_url

    assert_response :redirect
    assert Onchain::SecurityResolver.price_provider_enabled?
    assert_includes Setting.enabled_securities_providers, "twelve_data"
  end

  test "enable_crypto_prices is refused on a managed instance where the operator decides" do
    Setting.securities_providers = "twelve_data"

    post enable_crypto_prices_onchain_wallet_items_url

    assert_response :redirect
    assert_not Onchain::SecurityResolver.price_provider_enabled?
    assert_equal I18n.t("onchain_wallet_items.enable_crypto_prices.not_self_hosted"), flash[:alert]
  end

  test "a member without admin rights is not offered the one-click fix" do
    Rails.configuration.stubs(:app_mode).returns(ActiveSupport::StringInquirer.new("self_hosted"))
    sign_in users(:family_member)

    get manage_onchain_wallet_item_url(create_onchain_wallet_item(family: @family))

    assert_response :redirect
  end

  test "preview_wallet lists what the address holds, pre-checking only vouched-for assets" do
    stub_fake_snapshot(
      OnchainTestHelper::FAKE_ADDRESS,
      Onchain::Snapshot.new(
        assets: [
          fake_native_asset(quantity: 2),
          fake_token_asset(symbol: "USDC", contract: "0xusdc", quantity: 10),
          fake_token_asset(symbol: "Visit site to claim", contract: "0xspam", quantity: 1),
          # An airdrop with a perfectly plausible symbol: only the data source's
          # own signal separates it from the real thing.
          fake_token_asset(symbol: "0XBTC", contract: "0xairdrop", quantity: 1, notable: false)
        ],
        movements: []
      )
    )

    post preview_wallet_onchain_wallet_items_url, params: { address: OnchainTestHelper::FAKE_ADDRESS }

    assert_response :success
    assert_match "USDC", response.body
    assert_match I18n.t("onchain_wallet_items.token_review_form.no_price"), response.body
    assert_select "input[name='assets[]'][value='native'][checked]"
    assert_select "input[name='assets[]'][value='erc20:0xusdc'][checked]"
    assert_select "input[name='assets[]'][value='erc20:0xspam']"
    assert_select "input[name='assets[]'][value='erc20:0xspam'][checked]", false
    assert_select "input[name='assets[]'][value='erc20:0xairdrop']"
    assert_select "input[name='assets[]'][value='erc20:0xairdrop'][checked]", false
  end

  test "preview_wallet rejects an address that belongs to no supported chain" do
    post preview_wallet_onchain_wallet_items_url, params: { address: "definitely-not-an-address" }

    assert_response :unprocessable_entity
    assert_match I18n.t("onchain_wallet_items.errors.unrecognized_address"), response.body
  end

  test "preview_wallet asks which chain when several report activity" do
    other = "otherchain"
    Onchain::Chains.register(
      Onchain::Chains::Definition.new(
        key: other,
        native: Onchain::Chains::NativeAsset.new(symbol: "OTHER", name: "Other", decimals: 8),
        token_kind: nil,
        adapter_class_name: "OnchainTestHelper::FakeAdapter",
        adapter_options: {}
      )
    )

    post preview_wallet_onchain_wallet_items_url, params: { address: OnchainTestHelper::FAKE_ADDRESS }

    assert_response :success
    assert_match I18n.t("onchain_wallet_items.choose_chain.title"), response.body
    assert_match I18n.t("onchain_wallet_items.choose_chain.activity_found"), response.body
  ensure
    Onchain::Chains.unregister(other)
  end

  test "an expected explorer failure surfaces as a localized message" do
    OnchainTestHelper::FakeAdapter.error = Onchain::Chains::UnreachableError.new("blockscout down")

    post preview_wallet_onchain_wallet_items_url, params: { address: OnchainTestHelper::FAKE_ADDRESS }

    assert_response :unprocessable_entity
    assert_match I18n.t("onchain_wallet_items.errors.chain_unreachable"), response.body
    assert_no_match "blockscout down", response.body
  end

  test "a data source that times out reads as unreachable, not as our own failure" do
    OnchainTestHelper::FakeAdapter.error = Provider::MempoolSpace::ApiError.new("MempoolSpace is unavailable (Net::ReadTimeout)")
    OnchainTestHelper::FakeAdapter.provider_error_classes = [ Provider::MempoolSpace::RateLimitError, Provider::MempoolSpace::Error ]

    assert_no_difference "DebugLogEntry.count" do
      post preview_wallet_onchain_wallet_items_url, params: { address: OnchainTestHelper::FAKE_ADDRESS }
    end

    assert_response :unprocessable_entity
    assert_match I18n.t("onchain_wallet_items.errors.chain_unreachable"), response.body
    assert_no_match "Net::ReadTimeout", response.body
  end

  test "an unexpected failure is recorded and never interpolated into the response" do
    OnchainTestHelper::FakeAdapter.error = NoMethodError.new("undefined method 'boom' for nil")

    assert_difference "DebugLogEntry.count", 1 do
      post preview_wallet_onchain_wallet_items_url, params: { address: OnchainTestHelper::FAKE_ADDRESS }
    end

    assert_response :unprocessable_entity
    assert_match I18n.t("onchain_wallet_items.errors.unexpected"), response.body
    assert_no_match "undefined method", response.body
    assert_equal "onchain_wallet", DebugLogEntry.order(:created_at).last.provider_key
  end

  test "link_wallet tracks only the ticked assets and creates one account each" do
    stub_wallet_with_token

    assert_difference [ "OnchainWalletAccount.count", "Account.count" ], 1 do
      post link_wallet_onchain_wallet_items_url, params: {
        chain: OnchainTestHelper::FAKE_CHAIN,
        address: OnchainTestHelper::FAKE_ADDRESS,
        assets: [ "native" ]
      }
    end

    assert_redirected_to accounts_path
    onchain_account = OnchainWalletAccount.order(:created_at).last
    assert_equal "native", onchain_account.asset_kind
    assert_equal @family, onchain_account.onchain_wallet_item.family
    assert_equal "Crypto", onchain_account.account.accountable_type
    assert_equal "wallet", onchain_account.account.accountable.subtype
  end

  test "link_wallet ignores an asset the chain does not report" do
    stub_wallet_with_token

    assert_difference "OnchainWalletAccount.count", 1 do
      post link_wallet_onchain_wallet_items_url, params: {
        chain: OnchainTestHelper::FAKE_CHAIN,
        address: OnchainTestHelper::FAKE_ADDRESS,
        assets: [ "native", "erc20:0xnothere" ]
      }
    end
  end

  test "link_wallet refuses an address the family already tracks" do
    item = create_onchain_wallet_item(family: @family)
    link_onchain_wallet_account!(create_onchain_wallet_account(item: item))
    stub_wallet_with_token

    assert_no_difference "OnchainWalletAccount.count" do
      post link_wallet_onchain_wallet_items_url, params: {
        chain: OnchainTestHelper::FAKE_CHAIN,
        address: OnchainTestHelper::FAKE_ADDRESS,
        assets: [ "native" ]
      }
    end

    assert_response :unprocessable_entity
    assert_match I18n.t("onchain_wallet_items.errors.already_linked"), response.body
  end

  test "preview_wallet refuses an address the family already tracks" do
    item = create_onchain_wallet_item(family: @family)
    link_onchain_wallet_account!(create_onchain_wallet_account(item: item))

    post preview_wallet_onchain_wallet_items_url, params: {
      address: OnchainTestHelper::FAKE_ADDRESS,
      chain: OnchainTestHelper::FAKE_CHAIN
    }

    assert_response :unprocessable_entity
    assert_match I18n.t("onchain_wallet_items.errors.already_linked"), response.body
  end

  test "a failed read leaves no empty connection behind" do
    OnchainTestHelper::FakeAdapter.error = Onchain::Chains::UnreachableError.new("explorer down")

    assert_no_difference "OnchainWalletItem.count" do
      post link_wallet_onchain_wallet_items_url, params: {
        chain: OnchainTestHelper::FAKE_CHAIN,
        address: OnchainTestHelper::FAKE_ADDRESS,
        assets: [ "native" ]
      }
    end

    assert_response :unprocessable_entity
    assert_match I18n.t("onchain_wallet_items.errors.chain_unreachable"), response.body
  end

  test "assets that were ticked but could not be tracked are named, not blamed on the user" do
    stub_wallet_with_token
    OnchainWalletItem::WalletLinker.any_instance.stubs(:link).returns(
      OnchainWalletItem::WalletLinker::Result.new(created: 0, removed: 0, errors: [ "USDC" ])
    )

    post link_wallet_onchain_wallet_items_url, params: {
      chain: OnchainTestHelper::FAKE_CHAIN,
      address: OnchainTestHelper::FAKE_ADDRESS,
      assets: [ "erc20:0xusdc" ]
    }

    assert_response :unprocessable_entity
    assert_match "USDC", response.body
    # Being told to "pick at least one asset" would send them back to tick the
    # same one.
    assert_no_match I18n.t("onchain_wallet_items.link_wallet.errors.nothing_selected"), response.body
  end

  test "a partial failure is reported alongside what did get tracked" do
    stub_wallet_with_token
    OnchainWalletItem::WalletLinker.any_instance.stubs(:link).returns(
      OnchainWalletItem::WalletLinker::Result.new(created: 1, removed: 0, errors: [ "USDC" ])
    )

    post link_wallet_onchain_wallet_items_url, params: {
      chain: OnchainTestHelper::FAKE_CHAIN,
      address: OnchainTestHelper::FAKE_ADDRESS,
      assets: [ "native", "erc20:0xusdc" ]
    }

    assert_redirected_to accounts_path
    assert_match "USDC", flash[:alert]
  end

  test "the settings link is not offered to anyone who cannot open that page" do
    # Managed instance: market data is the operator's setting and the page is
    # gated, so a link there is a dead end. Asserted on the link's own text —
    # the settings layout mentions that path for its own reasons.
    link = I18n.t("onchain_wallet_items.price_provider_warning.link")

    get new_wallet_onchain_wallet_items_url
    assert_match I18n.t("onchain_wallet_items.price_provider_warning.title"), response.body
    assert_no_match link, response.body

    Rails.configuration.stubs(:app_mode).returns(ActiveSupport::StringInquirer.new("self_hosted"))
    get new_wallet_onchain_wallet_items_url
    assert_match link, response.body

    sign_in users(:family_member)
    get manage_onchain_wallet_item_url(create_onchain_wallet_item(family: @family))
    assert_response :redirect
  end

  test "link_wallet with nothing ticked reopens the selection" do
    stub_wallet_with_token

    assert_no_difference "OnchainWalletAccount.count" do
      post link_wallet_onchain_wallet_items_url, params: {
        chain: OnchainTestHelper::FAKE_CHAIN,
        address: OnchainTestHelper::FAKE_ADDRESS
      }
    end

    assert_response :unprocessable_entity
    assert_match I18n.t("onchain_wallet_items.link_wallet.errors.nothing_selected"), response.body
  end

  test "previewing an address never leaves an empty connection behind" do
    stub_wallet_with_token

    assert_no_difference "OnchainWalletItem.count" do
      post preview_wallet_onchain_wallet_items_url, params: { address: OnchainTestHelper::FAKE_ADDRESS }
    end
  end

  test "sync schedules a sync for the family's own connection only" do
    item = create_onchain_wallet_item(family: @family)
    other_family_item = create_onchain_wallet_item(family: families(:empty))

    post sync_onchain_wallet_item_url(item)
    assert_redirected_to settings_providers_path

    post sync_onchain_wallet_item_url(other_family_item)
    assert_response :not_found
  end

  test "destroy schedules the connection for deletion" do
    item = create_onchain_wallet_item(family: @family)

    delete onchain_wallet_item_url(item)

    assert_redirected_to settings_providers_path
    assert item.reload.scheduled_for_deletion
  end

  test "update stores an explorer key and keeps it when the field is left blank" do
    item = create_onchain_wallet_item(family: @family)

    patch onchain_wallet_item_url(item), params: { onchain_wallet_item: { etherscan_api_key: "abc123" } }
    assert_equal "abc123", item.reload.etherscan_api_key

    patch onchain_wallet_item_url(item), params: { onchain_wallet_item: { etherscan_api_key: "" } }
    assert_equal "abc123", item.reload.etherscan_api_key
  end

  test "update stores the date before which transfers are ignored" do
    item = create_onchain_wallet_item(family: @family)

    patch onchain_wallet_item_url(item), params: { onchain_wallet_item: { sync_start_date: "2026-01-15" } }

    assert_equal Date.new(2026, 1, 15), item.reload.sync_start_date.to_date
  end

  test "linking creates the single connection every wallet hangs off" do
    stub_wallet_with_token
    stub_wallet_with_token(address: OnchainTestHelper::FAKE_ADDRESS_ALT)

    assert_difference "OnchainWalletItem.count", 1 do
      post link_wallet_onchain_wallet_items_url, params: {
        chain: OnchainTestHelper::FAKE_CHAIN,
        address: OnchainTestHelper::FAKE_ADDRESS,
        assets: [ "native" ]
      }
    end

    assert_no_difference "OnchainWalletItem.count" do
      post link_wallet_onchain_wallet_items_url, params: {
        chain: OnchainTestHelper::FAKE_CHAIN,
        address: OnchainTestHelper::FAKE_ADDRESS_ALT,
        assets: [ "native" ]
      }
    end

    assert_equal 2, @family.reload.onchain_wallet_items.sole.wallet_keys.size
  end

  test "a member without admin rights cannot link a wallet" do
    sign_in users(:family_member)

    get new_wallet_onchain_wallet_items_url

    assert_response :redirect
  end

  test "manage lists every tracked address and offers its actions" do
    item = create_onchain_wallet_item(family: @family)
    native = create_onchain_wallet_account(item: item)
    token_asset = create_onchain_wallet_account(item: item, asset: fake_token_asset(symbol: "USDC", contract: "0xusdc"))

    get manage_onchain_wallet_item_url(item)

    assert_response :success
    assert_match OnchainTestHelper::FAKE_ADDRESS, response.body
    assert_match I18n.t("onchain_wallet_items.manage.review_tokens"), response.body
    assert_match I18n.t("onchain_wallet_items.manage.disconnect_wallet"), response.body
    # Per-asset action, for each asset, not just one for the wallet.
    assert_select "form[action=?]", disconnect_asset_onchain_wallet_item_path(item), count: 2
    # The per-address actions live in a menu, as the accounts page renders its
    # own repeated row actions.
    assert_select "form[action=?]", disconnect_wallet_onchain_wallet_item_path(item), count: 1
    assert_match native.symbol, response.body
    assert_match token_asset.symbol, response.body
  end

  test "review_tokens reopens the selection with the address unchanged" do
    item = create_onchain_wallet_item(family: @family)
    create_onchain_wallet_account(item: item)
    stub_wallet_with_token

    get review_tokens_onchain_wallet_item_url(item, chain: OnchainTestHelper::FAKE_CHAIN, address: OnchainTestHelper::FAKE_ADDRESS)

    assert_response :success
    assert_select "input[name=address][value=?]", OnchainTestHelper::FAKE_ADDRESS
    assert_select "input[name='new_address']", false
    assert_select "input[name='assets[]'][value='native'][checked]"
    assert_select "input[name='assets[]'][value='erc20:0xusdc'][checked]"
  end

  test "update_tokens adds a newly ticked asset and stops tracking an unticked one" do
    item = create_onchain_wallet_item(family: @family)
    native = create_onchain_wallet_account(item: item)
    stub_wallet_with_token

    assert_difference "OnchainWalletAccount.count", 0 do
      post update_tokens_onchain_wallet_item_url(item), params: {
        chain: OnchainTestHelper::FAKE_CHAIN,
        address: OnchainTestHelper::FAKE_ADDRESS,
        assets: [ "erc20:0xusdc" ]
      }
    end

    assert_redirected_to manage_onchain_wallet_item_path(item)
    assert_not OnchainWalletAccount.exists?(native.id)
    assert_equal [ "USDC" ], item.reload.onchain_wallet_accounts.pluck(:symbol)
  end

  test "unticking one asset removes only it" do
    item = create_onchain_wallet_item(family: @family)
    # Linked, because that is what a tracked asset actually is. Left unlinked
    # these are orphan rows, and revising now rebuilds those into real ones —
    # so the surviving row would be a new one and the assertion below would be
    # measuring the repair rather than the removal.
    native = create_onchain_wallet_account(item: item)
    link_onchain_wallet_account!(native)
    token_asset = create_onchain_wallet_account(item: item, asset: fake_token_asset(symbol: "USDC", contract: "0xusdc"))
    link_onchain_wallet_account!(token_asset)
    stub_wallet_with_token

    post update_tokens_onchain_wallet_item_url(item), params: {
      chain: OnchainTestHelper::FAKE_CHAIN,
      address: OnchainTestHelper::FAKE_ADDRESS,
      assets: [ "native" ]
    }

    assert OnchainWalletAccount.exists?(native.id)
    assert_not OnchainWalletAccount.exists?(token_asset.id)
  end

  test "an asset the chain no longer reports can still be unticked" do
    item = create_onchain_wallet_item(family: @family)
    gone = create_onchain_wallet_account(item: item, asset: fake_token_asset(symbol: "GONE", contract: "0xgone"))
    create_onchain_wallet_account(item: item)
    stub_wallet_with_token

    get review_tokens_onchain_wallet_item_url(item, chain: OnchainTestHelper::FAKE_CHAIN, address: OnchainTestHelper::FAKE_ADDRESS)
    assert_select "input[name='assets[]'][value='erc20:0xgone'][checked]"

    post update_tokens_onchain_wallet_item_url(item), params: {
      chain: OnchainTestHelper::FAKE_CHAIN,
      address: OnchainTestHelper::FAKE_ADDRESS,
      assets: [ "native" ]
    }

    assert_not OnchainWalletAccount.exists?(gone.id)
  end

  test "disconnect_wallet stops tracking every asset at that address only" do
    item = create_onchain_wallet_item(family: @family)
    create_onchain_wallet_account(item: item)
    create_onchain_wallet_account(item: item, asset: fake_token_asset(contract: "0xusdc"))
    kept = create_onchain_wallet_account(item: item, address: OnchainTestHelper::FAKE_ADDRESS_ALT)

    assert_difference "OnchainWalletAccount.count", -2 do
      delete disconnect_wallet_onchain_wallet_item_url(item), params: {
        chain: OnchainTestHelper::FAKE_CHAIN,
        address: OnchainTestHelper::FAKE_ADDRESS
      }
    end

    assert OnchainWalletAccount.exists?(kept.id)
  end

  test "disconnecting keeps the account and its holdings as a manual account" do
    item = create_onchain_wallet_item(family: @family)
    onchain_account = create_onchain_wallet_account(item: item)
    account = link_onchain_wallet_account!(onchain_account)
    security = Onchain::SecurityResolver.resolve(symbol: onchain_account.symbol)
    holding = account.holdings.create!(
      security: security, date: Date.current, qty: 1, price: 1, amount: 1,
      currency: account.currency, account_provider_id: onchain_account.account_provider.id
    )

    delete disconnect_asset_onchain_wallet_item_url(item), params: { onchain_wallet_account_id: onchain_account.id }

    assert Account.exists?(account.id)
    assert holding.reload.persisted?
    assert_nil holding.account_provider_id
    assert_not AccountProvider.exists?(provider_type: "OnchainWalletAccount", provider_id: onchain_account.id)
  end

  test "management actions refuse a wallet this connection does not track" do
    item = create_onchain_wallet_item(family: @family)
    create_onchain_wallet_account(item: item)

    get review_tokens_onchain_wallet_item_url(item, chain: OnchainTestHelper::FAKE_CHAIN, address: OnchainTestHelper::FAKE_ADDRESS_ALT)

    assert_redirected_to manage_onchain_wallet_item_path(item)
    assert_equal I18n.t("onchain_wallet_items.errors.wallet_not_found"), flash[:alert]
  end

  test "management actions cannot reach another family's connection" do
    other_family_item = create_onchain_wallet_item(family: families(:empty))
    create_onchain_wallet_account(item: other_family_item)

    get manage_onchain_wallet_item_url(other_family_item)
    assert_response :not_found

    delete disconnect_wallet_onchain_wallet_item_url(other_family_item), params: {
      chain: OnchainTestHelper::FAKE_CHAIN,
      address: OnchainTestHelper::FAKE_ADDRESS
    }
    assert_response :not_found
    assert_equal 1, other_family_item.onchain_wallet_accounts.count
  end

  test "disconnect_asset cannot reach a row belonging to another connection" do
    item = create_onchain_wallet_item(family: @family)
    other_item = create_onchain_wallet_item(family: families(:empty))
    other_account = create_onchain_wallet_account(item: other_item)

    delete disconnect_asset_onchain_wallet_item_url(item), params: { onchain_wallet_account_id: other_account.id }

    assert_response :not_found
    assert OnchainWalletAccount.exists?(other_account.id)
  end

  private
    def stub_wallet_with_token(address: OnchainTestHelper::FAKE_ADDRESS)
      stub_fake_snapshot(
        address,
        Onchain::Snapshot.new(
          assets: [ fake_native_asset(quantity: 2), fake_token_asset(symbol: "USDC", contract: "0xusdc", quantity: 10) ],
          movements: []
        )
      )
    end
end
