# frozen_string_literal: true

require "test_helper"

class OnchainWalletItem::WalletLinkerTest < ActiveSupport::TestCase
  include OnchainTestHelper

  setup do
    register_fake_chain!
    @item = create_onchain_wallet_item(family: families(:dylan_family))
  end

  teardown do
    unregister_fake_chain!
  end

  test "a row left behind by a deleted account does not block tracking the asset again" do
    leftover = create_onchain_wallet_account(item: @item)

    # What an instance carrying the old destroy bug looks like: the row survived
    # its account, and its partial unique index still holds the asset's slot.
    assert leftover.account_provider.blank?

    result = link(fake_native_asset)

    assert_equal 1, result.created
    assert_empty result.errors
    assert_not OnchainWalletAccount.exists?(leftover.id), "the dead row should have made way rather than sit alongside"

    tracked = @item.onchain_wallet_accounts.sole
    assert tracked.account_provider.present?
  end

  test "a row that still tracks an account is left alone" do
    tracked = create_onchain_wallet_account(item: @item)
    link_onchain_wallet_account!(tracked)

    result = link(fake_native_asset)

    # Nothing to absorb here: the asset is already tracked, so the duplicate is
    # refused rather than allowed to replace a live account.
    assert_equal 0, result.created
    assert_equal [ "FAKE" ], result.errors
    assert OnchainWalletAccount.exists?(tracked.id)
  end

  # --- Review follow-ups (#3182) ---

  # An orphan row tracks nothing, yet `grouped_accounts` and token review show
  # it as tracked. Clearing only the rows matching what was picked left the
  # others claiming assets that have no account behind them.
  test "reclaiming an address clears the rows it left behind, not just the picked ones" do
    picked = create_onchain_wallet_account(item: @item)
    stranded = create_onchain_wallet_account(item: @item, asset: fake_token_asset(contract: "0xdead"))

    assert stranded.account_provider.blank?

    result = link(fake_native_asset)

    assert_equal 1, result.created
    assert_not OnchainWalletAccount.exists?(picked.id)
    assert_not OnchainWalletAccount.exists?(stranded.id),
      "an orphan nobody picked kept claiming its asset"
  end

  # A live row belongs to somebody. Reclaiming the address must not sweep it up
  # alongside the dead ones.
  test "reclaiming an address leaves a live row alone" do
    live = create_onchain_wallet_account(item: @item, asset: fake_token_asset(contract: "0xbeef"))
    link_onchain_wallet_account!(live)

    link(fake_native_asset)

    assert OnchainWalletAccount.exists?(live.id)
  end

  # `revise` counted any matching row as tracked, orphans included, so ticking
  # an asset whose account had been deleted did nothing at all: no Account, no
  # AccountProvider, the row still orphaned — and the screen still saying it
  # was tracked.
  test "reviving an orphaned asset actually rebuilds its account" do
    orphan = create_onchain_wallet_account(item: @item)
    assert orphan.account_provider.blank?

    result = revise(fake_native_asset)

    assert_equal 1, result.created
    assert_not OnchainWalletAccount.exists?(orphan.id)

    rebuilt = @item.onchain_wallet_accounts.sole
    assert rebuilt.account_provider.present?, "the asset came back tracking nothing"
  end

  test "revising leaves an asset that is already properly tracked alone" do
    tracked = create_onchain_wallet_account(item: @item)
    link_onchain_wallet_account!(tracked)

    result = revise(fake_native_asset)

    assert_equal 0, result.created
    assert_equal 0, result.removed
    assert OnchainWalletAccount.exists?(tracked.id)
  end

  test "unticking an asset stops tracking it" do
    tracked = create_onchain_wallet_account(item: @item)
    link_onchain_wallet_account!(tracked)

    result = revise

    assert_equal 1, result.removed
    assert_not OnchainWalletAccount.exists?(tracked.id)
  end

  private

    def revise(*assets)
      snapshot = Onchain::Snapshot.new(assets: assets, movements: [])

      OnchainWalletItem::WalletLinker
        .new(@item, chain: FAKE_CHAIN, address: FAKE_ADDRESS)
        .revise(snapshot: snapshot, selected_keys: assets.map { |a| OnchainWalletItem::TokenReview.key_for(a) })
    end
    def link(*assets)
      snapshot = Onchain::Snapshot.new(assets: assets, movements: [])

      OnchainWalletItem::WalletLinker
        .new(@item, chain: FAKE_CHAIN, address: FAKE_ADDRESS)
        .link(snapshot: snapshot, selected_keys: assets.map { |a| OnchainWalletItem::TokenReview.key_for(a) })
    end
end
