# frozen_string_literal: true

require "test_helper"

class OnchainWalletItem::ImporterTest < ActiveSupport::TestCase
  include OnchainTestHelper

  setup do
    register_fake_chain!
    @family = families(:dylan_family)
    @item = create_onchain_wallet_item(family: @family)
  end

  teardown do
    unregister_fake_chain!
  end

  test "records the quantity and movements of each tracked asset" do
    account = create_onchain_wallet_account(item: @item, asset: fake_native_asset(quantity: 0))
    stub_fake_snapshot(
      OnchainTestHelper::FAKE_ADDRESS,
      Onchain::Snapshot.new(
        assets: [ fake_native_asset(quantity: "2.5") ],
        movements: [ fake_movement(external_id: "tx1", amount: "2.5") ]
      )
    )

    result = OnchainWalletItem::Importer.new(@item).import

    assert_equal [ account.id ], result[:changed_account_ids]
    account.reload
    assert_equal BigDecimal("2.5"), account.quantity
    assert_equal "2.5", account.raw_payload["quantity"]
    assert_equal [ "tx1" ], account.raw_movements_payload["movements"].map { |m| m["external_id"] }
    assert account.content_hash.present?
  end

  test "does not create rows for assets the user never chose to track" do
    create_onchain_wallet_account(item: @item)
    stub_fake_snapshot(
      OnchainTestHelper::FAKE_ADDRESS,
      Onchain::Snapshot.new(
        assets: [ fake_native_asset, fake_token_asset(symbol: "SPAM", contract: "0xspam") ],
        movements: []
      )
    )

    assert_no_difference "OnchainWalletAccount.count" do
      OnchainWalletItem::Importer.new(@item).import
    end
  end

  test "an asset that disappeared from the wallet is set to zero" do
    account = create_onchain_wallet_account(item: @item, asset: fake_token_asset(contract: "0xaaa", quantity: 10))
    stub_fake_snapshot(OnchainTestHelper::FAKE_ADDRESS, Onchain::Snapshot.new(assets: [ fake_native_asset ], movements: []))

    OnchainWalletItem::Importer.new(@item).import

    assert_equal 0, account.reload.quantity
  end

  test "a second import of an unchanged wallet writes nothing" do
    account = create_onchain_wallet_account(item: @item)
    stub_fake_snapshot(
      OnchainTestHelper::FAKE_ADDRESS,
      Onchain::Snapshot.new(assets: [ fake_native_asset ], movements: [ fake_movement(external_id: "tx1") ])
    )

    OnchainWalletItem::Importer.new(@item).import
    updated_at = account.reload.updated_at

    result = OnchainWalletItem::Importer.new(@item).import

    assert_empty result[:changed_account_ids]
    assert_equal updated_at, account.reload.updated_at
  end

  test "a changed quantity is detected even when the movements are identical" do
    account = create_onchain_wallet_account(item: @item)
    movements = [ fake_movement(external_id: "tx1") ]
    stub_fake_snapshot(OnchainTestHelper::FAKE_ADDRESS, Onchain::Snapshot.new(assets: [ fake_native_asset(quantity: 1) ], movements: movements))
    OnchainWalletItem::Importer.new(@item).import

    stub_fake_snapshot(OnchainTestHelper::FAKE_ADDRESS, Onchain::Snapshot.new(assets: [ fake_native_asset(quantity: 2) ], movements: movements))
    result = OnchainWalletItem::Importer.new(@item).import

    assert_equal [ account.id ], result[:changed_account_ids]
    assert_equal 2, account.reload.quantity
  end

  test "reads each tracked address exactly once" do
    create_onchain_wallet_account(item: @item)
    create_onchain_wallet_account(item: @item, asset: fake_token_asset(contract: "0xaaa"))
    create_onchain_wallet_account(item: @item, address: OnchainTestHelper::FAKE_ADDRESS_ALT)

    OnchainWalletItem::Importer.new(@item).import

    assert_equal(
      [ OnchainTestHelper::FAKE_ADDRESS, OnchainTestHelper::FAKE_ADDRESS_ALT ].sort,
      OnchainTestHelper::FakeAdapter.snapshot_calls.sort
    )
  end

  test "a truncated history is recorded on the row and reported once per address" do
    account = create_onchain_wallet_account(item: @item)
    stub_fake_snapshot(
      OnchainTestHelper::FAKE_ADDRESS,
      Onchain::Snapshot.new(assets: [ fake_native_asset ], movements: [], history_truncated: true)
    )

    assert_difference "DebugLogEntry.count", 1 do
      OnchainWalletItem::Importer.new(@item).import
    end

    assert account.reload.history_truncated?
    entry = DebugLogEntry.order(:created_at).last
    assert_equal "onchain_wallet", entry.provider_key
    assert_equal OnchainTestHelper::FAKE_ADDRESS, entry.metadata["address"]
  end

  test "one report per address even when several assets are tracked there" do
    create_onchain_wallet_account(item: @item)
    create_onchain_wallet_account(item: @item, asset: fake_token_asset(contract: "0xaaa"))
    stub_fake_snapshot(
      OnchainTestHelper::FAKE_ADDRESS,
      Onchain::Snapshot.new(
        assets: [ fake_native_asset, fake_token_asset(contract: "0xaaa") ],
        movements: [],
        history_truncated: true
      )
    )

    assert_difference "DebugLogEntry.count", 1 do
      OnchainWalletItem::Importer.new(@item).import
    end
  end

  test "an idle wallet with deep history is not reported again on every sync" do
    create_onchain_wallet_account(item: @item)
    stub_fake_snapshot(
      OnchainTestHelper::FAKE_ADDRESS,
      Onchain::Snapshot.new(assets: [ fake_native_asset ], movements: [], history_truncated: true)
    )
    OnchainWalletItem::Importer.new(@item).import

    assert_no_difference "DebugLogEntry.count" do
      OnchainWalletItem::Importer.new(@item).import
    end
  end

  test "a complete history clears the truncation flag" do
    account = create_onchain_wallet_account(item: @item)
    stub_fake_snapshot(
      OnchainTestHelper::FAKE_ADDRESS,
      Onchain::Snapshot.new(assets: [ fake_native_asset(quantity: 1) ], movements: [], history_truncated: true)
    )
    OnchainWalletItem::Importer.new(@item).import
    assert account.reload.history_truncated?

    stub_fake_snapshot(
      OnchainTestHelper::FAKE_ADDRESS,
      Onchain::Snapshot.new(assets: [ fake_native_asset(quantity: 2) ], movements: [], history_truncated: false)
    )
    OnchainWalletItem::Importer.new(@item).import

    assert_not account.reload.history_truncated?
  end

  test "movements before the connection start date are ignored" do
    account = create_onchain_wallet_account(item: @item)
    @item.update!(sync_start_date: 2.days.ago.to_date)
    stub_fake_snapshot(
      OnchainTestHelper::FAKE_ADDRESS,
      Onchain::Snapshot.new(
        assets: [ fake_native_asset ],
        movements: [
          fake_movement(external_id: "old", timestamp: 10.days.ago.to_date),
          fake_movement(external_id: "recent", timestamp: Date.current)
        ]
      )
    )

    OnchainWalletItem::Importer.new(@item).import

    assert_equal [ "recent" ], account.reload.raw_movements_payload["movements"].map { |m| m["external_id"] }
  end
end
