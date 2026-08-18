# frozen_string_literal: true

require "test_helper"

class OnchainWalletItem::SyncerTest < ActiveSupport::TestCase
  include OnchainTestHelper

  setup do
    register_fake_chain!
    @family = families(:dylan_family)
    @item = create_onchain_wallet_item(family: @family)
    @onchain_account = create_onchain_wallet_account(item: @item, asset: fake_native_asset(quantity: 0))
    @account = link_onchain_wallet_account!(@onchain_account)
    @sync = @item.syncs.create!
  end

  teardown do
    unregister_fake_chain!
  end

  test "processes an asset whose on-chain state changed" do
    stub_wallet(quantity: "2")

    OnchainWalletAccount::Processor.any_instance.expects(:process).once

    OnchainWalletItem::Syncer.new(@item).perform_sync(@sync)

    assert_equal BigDecimal("2"), @onchain_account.reload.quantity
  end

  test "a second sync with no on-chain change writes nothing and processes nothing" do
    stub_wallet(quantity: "2")
    OnchainWalletItem::Syncer.new(@item).perform_sync(@sync)

    account_updated_at = @onchain_account.reload.updated_at
    holdings = Holding.count
    entries = Entry.count
    syncs = Sync.count

    OnchainWalletAccount::Processor.any_instance.expects(:process).never

    OnchainWalletItem::Syncer.new(@item).perform_sync(@item.syncs.create!)

    assert_equal account_updated_at, @onchain_account.reload.updated_at
    assert_equal holdings, Holding.count
    assert_equal entries, Entry.count
    # Only the sync record this test created itself; no account syncs queued.
    assert_equal syncs + 1, Sync.count
  end

  test "does not process an asset that is not linked to an account" do
    unlinked = create_onchain_wallet_account(item: @item, asset: fake_token_asset(contract: "0xaaa"))
    stub_wallet(quantity: "2", assets: [ fake_native_asset(quantity: "2"), fake_token_asset(contract: "0xaaa", quantity: 5) ])

    OnchainWalletAccount::Processor.any_instance.expects(:process).once

    OnchainWalletItem::Syncer.new(@item).perform_sync(@sync)

    assert_equal 5, unlinked.reload.quantity
  end

  test "records a debug log entry and re-raises when a chain is unreachable" do
    OnchainTestHelper::FakeAdapter.error = StandardError.new("chain unreachable")

    assert_difference "DebugLogEntry.count", 1 do
      assert_raises StandardError do
        OnchainWalletItem::Syncer.new(@item).perform_sync(@sync)
      end
    end

    entry = DebugLogEntry.order(:created_at).last
    assert_equal "onchain_wallet", entry.provider_key
    assert_equal @family, entry.family
    assert_equal "error", entry.level
  end

  private
    def stub_wallet(quantity: "1", assets: nil)
      stub_fake_snapshot(
        OnchainTestHelper::FAKE_ADDRESS,
        Onchain::Snapshot.new(assets: assets || [ fake_native_asset(quantity: quantity) ], movements: [])
      )
    end
end
