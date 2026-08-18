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
    assert_match I18n.t("onchain_wallet_items.new_wallet.read_only_note"), response.body
  end

  test "the settings panel renders before anything is linked" do
    get connect_form_settings_providers_path(provider_key: "onchain_wallet")

    assert_response :success
    assert_match I18n.t("settings.providers.onchain_wallet_panel.keyless_title"), response.body
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
  end

  test "the price provider warning appears only when no crypto provider is enabled" do
    get new_wallet_onchain_wallet_items_url
    assert_match I18n.t("onchain_wallet_items.price_provider_warning.title"), response.body

    Setting.stubs(:enabled_securities_providers).returns([ Onchain::SecurityResolver::PRICE_PROVIDER ])

    get new_wallet_onchain_wallet_items_url
    assert_no_match I18n.t("onchain_wallet_items.price_provider_warning.title"), response.body
  end

  test "preview_wallet lists what the address holds, pre-checking only priceable assets" do
    stub_fake_snapshot(
      OnchainTestHelper::FAKE_ADDRESS,
      Onchain::Snapshot.new(
        assets: [
          fake_native_asset(quantity: 2),
          fake_token_asset(symbol: "USDC", contract: "0xusdc", quantity: 10),
          fake_token_asset(symbol: "Visit site to claim", contract: "0xspam", quantity: 1)
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
    create_onchain_wallet_account(item: item)
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
    create_onchain_wallet_account(item: item)

    post preview_wallet_onchain_wallet_items_url, params: {
      address: OnchainTestHelper::FAKE_ADDRESS,
      chain: OnchainTestHelper::FAKE_CHAIN
    }

    assert_response :unprocessable_entity
    assert_match I18n.t("onchain_wallet_items.errors.already_linked"), response.body
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
