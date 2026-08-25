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

  private
    def link(*assets)
      snapshot = Onchain::Snapshot.new(assets: assets, movements: [])

      OnchainWalletItem::WalletLinker
        .new(@item, chain: FAKE_CHAIN, address: FAKE_ADDRESS)
        .link(snapshot: snapshot, selected_keys: assets.map { |a| OnchainWalletItem::TokenReview.key_for(a) })
    end
end
