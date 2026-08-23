# frozen_string_literal: true

require "application_system_test_case"

# The linking flow spans three Turbo frame navigations stacked on top of each
# other (provider drawer → linking modal → token_asset review), which no controller
# test exercises. This walks it in a real browser once; the branching cases stay
# in the controller test.
class OnchainWalletsTest < ApplicationSystemTestCase
  include OnchainTestHelper

  setup do
    register_fake_chain!
    stub_fake_snapshot(
      OnchainTestHelper::FAKE_ADDRESS,
      Onchain::Snapshot.new(
        assets: [
          fake_native_asset(quantity: 2),
          fake_token_asset(symbol: "USDC", contract: "0xusdc", quantity: 250),
          fake_token_asset(symbol: "Visit site to claim", contract: "0xspam", quantity: 1)
        ],
        movements: []
      )
    )
    sign_in users(:family_admin)
  end

  teardown do
    unregister_fake_chain!
  end

  # The panel is reached two different ways depending on whether anything is
  # linked yet: as a card in "Available" opening the drawer, or as a disclosure
  # row under "Your connections" with the panel rendered inline.
  def open_onchain_panel
    if page.has_selector?("summary", text: "On-chain wallets", wait: 2)
      find("summary", text: "On-chain wallets").click
    else
      click_on "On-chain wallets"
    end
  end

  test "linking a wallet from the settings panel creates an account per ticked asset" do
    visit settings_providers_path
    open_onchain_panel

    # The provider panel opens in the drawer frame.
    assert_text I18n.t("onchain_wallet_items.price_provider_warning.title")

    # The read-only reassurance is no longer a permanent banner here...
    assert_no_text I18n.t("settings.providers.onchain_wallet_panel.keyless_title")

    click_on I18n.t("settings.providers.onchain_wallet_panel.add_wallet")

    # ...it lives where the address is pasted. Scoped to the modal, because a
    # page-wide assertion would pass from any frame and prove nothing about
    # where the banner actually went.
    within "turbo-frame#modal" do
      assert_text I18n.t("settings.providers.onchain_wallet_panel.keyless_title")
    end

    # The linking modal opens on top of the drawer.
    assert_text I18n.t("onchain_wallet_items.new_wallet.title")
    assert_text I18n.t("onchain_wallet_items.new_wallet.bitcoin_single_address_note")

    fill_in I18n.t("onchain_wallet_items.new_wallet.address_label"), with: OnchainTestHelper::FAKE_ADDRESS
    click_on I18n.t("onchain_wallet_items.new_wallet.continue")

    # Token review, in the same modal frame.
    assert_text I18n.t("onchain_wallet_items.token_review.title")
    assert_text "USDC"
    assert_text I18n.t("onchain_wallet_items.token_review_form.no_price")

    # Priceable assets arrive ticked, the unpriceable one does not.
    assert find("input[value='native']").checked?
    assert find("input[value='erc20:0xusdc']").checked?
    assert_not find("input[value='erc20:0xspam']").checked?

    assert_difference -> { Account.count }, 2 do
      click_on I18n.t("onchain_wallet_items.token_review.import_selected")
      assert_text I18n.t("onchain_wallet_items.link_wallet.success", count: 2)
    end

    assert_equal %w[FAKE USDC], OnchainWalletAccount.order(:symbol).pluck(:symbol)
  end

  test "managing a wallet reviews its tokens and disconnects one asset" do
    item = create_onchain_wallet_item(family: families(:dylan_family))
    native = create_onchain_wallet_account(item: item)
    native_account = link_onchain_wallet_account!(native)
    token_asset = create_onchain_wallet_account(item: item, asset: fake_token_asset(symbol: "USDC", contract: "0xusdc"))
    token_account = link_onchain_wallet_account!(token_asset)

    visit settings_providers_path
    open_onchain_panel
    click_on I18n.t("settings.providers.onchain_wallet_panel.manage_wallets")

    assert_text I18n.t("onchain_wallet_items.manage.title")
    assert_text OnchainTestHelper::FAKE_ADDRESS

    # The per-address actions live in a menu, as repeated row actions do
    # everywhere else in this app.
    find("[aria-haspopup='menu']", match: :first).click
    click_on I18n.t("onchain_wallet_items.manage.review_tokens")
    assert_text I18n.t("onchain_wallet_items.review_tokens.title")
    assert_no_selector "input[name='new_address']"

    uncheck "asset_erc20-0xusdc"
    click_on I18n.t("onchain_wallet_items.review_tokens.save")

    assert_text I18n.t("onchain_wallet_items.manage.title")
    assert_not OnchainWalletAccount.exists?(token_asset.id)
    assert OnchainWalletAccount.exists?(native.id)
    # Disconnecting keeps the account behind, it only stops updating.
    assert Account.exists?(token_account.id)
    assert Account.exists?(native_account.id)
    assert_not AccountProvider.exists?(provider_type: "OnchainWalletAccount", provider_id: token_asset.id)
  end
end
