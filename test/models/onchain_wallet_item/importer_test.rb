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

  test "an asset the cap never reached keeps its balance instead of being zeroed" do
    tracked = create_onchain_wallet_account(item: @item, asset: fake_token_asset(contract: "0xaaa", quantity: 42))
    stub_fake_snapshot(
      OnchainTestHelper::FAKE_ADDRESS,
      # The token is not in the snapshot because the read stopped at the cap,
      # not because the wallet stopped holding it.
      Onchain::Snapshot.new(assets: [ fake_native_asset ], movements: [], assets_truncated: true)
    )

    OnchainWalletItem::Importer.new(@item).import

    assert_equal 42, tracked.reload.quantity
    assert tracked.assets_truncated?
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

  test "a capped token list is recorded on the row and named in the report" do
    account = create_onchain_wallet_account(item: @item)
    stub_fake_snapshot(
      OnchainTestHelper::FAKE_ADDRESS,
      Onchain::Snapshot.new(assets: [ fake_native_asset ], movements: [], assets_truncated: true)
    )

    assert_difference "DebugLogEntry.count", 1 do
      OnchainWalletItem::Importer.new(@item).import
    end

    assert account.reload.assets_truncated?
    assert_not account.history_truncated?
    entry = DebugLogEntry.order(:created_at).last
    assert_match "not every token held is surfaced", entry.message
    assert_equal Onchain::AssetBudget.tokens, entry.metadata["max_tokens"]
  end

  test "one unreachable address does not stop the others from importing" do
    reachable = create_onchain_wallet_account(item: @item)
    unreachable = create_onchain_wallet_account(item: @item, address: OnchainTestHelper::FAKE_ADDRESS_ALT)
    stub_fake_snapshot(
      OnchainTestHelper::FAKE_ADDRESS,
      Onchain::Snapshot.new(assets: [ fake_native_asset(quantity: 3) ], movements: [])
    )
    OnchainTestHelper::FakeAdapter.errors_by_address[OnchainTestHelper::FAKE_ADDRESS_ALT] =
      Onchain::Chains::UnreachableError.new("explorer down")

    result = nil
    assert_difference "DebugLogEntry.count", 1 do
      result = OnchainWalletItem::Importer.new(@item).import
    end

    assert_equal [ reachable.id ], result[:changed_account_ids]
    assert_equal 1, result[:wallets_failed]
    assert_equal 3, reachable.reload.quantity
    # Untouched rather than zeroed: we did not learn that it holds nothing, we
    # failed to look.
    assert_equal BigDecimal("1.5"), unreachable.reload.quantity
    assert_nil unreachable.content_hash
  end

  test "a wallet whose every address failed is a failed sync, not a quiet success" do
    create_onchain_wallet_account(item: @item)
    OnchainTestHelper::FakeAdapter.error = Onchain::Chains::UnreachableError.new("explorer down")

    assert_raises Onchain::Chains::UnreachableError do
      OnchainWalletItem::Importer.new(@item).import
    end
  end

  test "a symbol that arrives later replaces the placeholder it was given" do
    placeholder = fake_token_asset(symbol: "SPL:abcd…wxyz", contract: "0xaaa", quantity: 5, name: "SPL token")
    account = create_onchain_wallet_account(item: @item, asset: placeholder)
    stub_fake_snapshot(OnchainTestHelper::FAKE_ADDRESS, Onchain::Snapshot.new(assets: [ placeholder ], movements: []))
    OnchainWalletItem::Importer.new(@item).import
    assert_equal "SPL:abcd…wxyz", account.reload.symbol

    # Same quantity, same movements, only the name is known now: the digest has to
    # notice, or the placeholder is permanent.
    named = fake_token_asset(symbol: "PYTH", contract: "0xaaa", quantity: 5, name: "Pyth Network")
    stub_fake_snapshot(OnchainTestHelper::FAKE_ADDRESS, Onchain::Snapshot.new(assets: [ named ], movements: []))

    result = OnchainWalletItem::Importer.new(@item).import

    assert_equal [ account.id ], result[:changed_account_ids]
    assert_equal "PYTH", account.reload.symbol
    assert_equal "Pyth Network", account.name
  end

  test "a non-finite quantity is not written to the database" do
    account = create_onchain_wallet_account(item: @item)
    stub_fake_snapshot(
      OnchainTestHelper::FAKE_ADDRESS,
      Onchain::Snapshot.new(
        assets: [ fake_chain.native_asset(quantity: BigDecimal("NaN")) ],
        movements: []
      )
    )

    OnchainWalletItem::Importer.new(@item).import

    # Postgres numeric would have stored NaN, and every total reading it would
    # have become NaN too.
    assert_predicate account.reload.quantity, :finite?
    assert_equal 0, account.quantity
  end

  test "a truncation flag that changes on its own still updates the row" do
    account = create_onchain_wallet_account(item: @item)
    asset = fake_native_asset(quantity: 2)
    movements = [ fake_movement(external_id: "tx1") ]

    stub_fake_snapshot(
      OnchainTestHelper::FAKE_ADDRESS,
      Onchain::Snapshot.new(assets: [ asset ], movements: movements, history_truncated: true)
    )
    OnchainWalletItem::Importer.new(@item).import
    assert account.reload.history_truncated?

    # Same quantity, same movements: only the completeness of the read changed.
    # Missed, the UI keeps claiming an incomplete history forever.
    stub_fake_snapshot(
      OnchainTestHelper::FAKE_ADDRESS,
      Onchain::Snapshot.new(assets: [ asset ], movements: movements, history_truncated: false)
    )

    result = OnchainWalletItem::Importer.new(@item).import

    assert_equal [ account.id ], result[:changed_account_ids]
    assert_not account.reload.history_truncated?
  end

  test "an asset cap that starts applying updates the row too" do
    account = create_onchain_wallet_account(item: @item)
    asset = fake_native_asset(quantity: 2)

    stub_fake_snapshot(OnchainTestHelper::FAKE_ADDRESS, Onchain::Snapshot.new(assets: [ asset ], movements: []))
    OnchainWalletItem::Importer.new(@item).import
    assert_not account.reload.assets_truncated?

    stub_fake_snapshot(
      OnchainTestHelper::FAKE_ADDRESS,
      Onchain::Snapshot.new(assets: [ asset ], movements: [], assets_truncated: true)
    )

    assert_equal [ account.id ], OnchainWalletItem::Importer.new(@item).import[:changed_account_ids]
    assert account.reload.assets_truncated?
  end

  test "the order a source lists movements in does not count as a change" do
    account = create_onchain_wallet_account(item: @item)
    first = fake_movement(external_id: "aaa", timestamp: 2.days.ago.to_date)
    second = fake_movement(external_id: "bbb", timestamp: 2.days.ago.to_date)

    stub_fake_snapshot(
      OnchainTestHelper::FAKE_ADDRESS,
      Onchain::Snapshot.new(assets: [ fake_native_asset ], movements: [ first, second ])
    )
    OnchainWalletItem::Importer.new(@item).import
    updated_at = account.reload.updated_at

    # The same two movements, listed the other way round.
    stub_fake_snapshot(
      OnchainTestHelper::FAKE_ADDRESS,
      Onchain::Snapshot.new(assets: [ fake_native_asset ], movements: [ second, first ])
    )

    assert_empty OnchainWalletItem::Importer.new(@item).import[:changed_account_ids]
    assert_equal updated_at, account.reload.updated_at
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
