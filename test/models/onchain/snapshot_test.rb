# frozen_string_literal: true

require "test_helper"

class Onchain::SnapshotTest < ActiveSupport::TestCase
  include OnchainTestHelper

  setup do
    register_fake_chain!
  end

  teardown do
    unregister_fake_chain!
  end

  test "movements_for matches tokens on contract regardless of case" do
    token_asset = fake_token_asset(contract: "0xAAA")
    matching = fake_movement(external_id: "a", symbol: "FUSD", contract: "0xaaa")
    other = fake_movement(external_id: "b", symbol: "FUSD", contract: "0xbbb")
    snapshot = Onchain::Snapshot.new(assets: [ token_asset ], movements: [ matching, other ])

    assert_equal [ "a" ], snapshot.movements_for(token_asset).map(&:external_id)
  end

  test "movements_for matches native assets on symbol and ignores token movements" do
    native = fake_native_asset
    native_movement = fake_movement(external_id: "native", symbol: "FAKE")
    token_movement = fake_movement(external_id: "token", symbol: "FAKE", contract: "0xaaa")
    snapshot = Onchain::Snapshot.new(assets: [ native ], movements: [ native_movement, token_movement ])

    assert_equal [ "native" ], snapshot.movements_for(native).map(&:external_id)
  end

  test "find_asset looks an asset up by kind and contract" do
    native = fake_native_asset
    token_asset = fake_token_asset(contract: "0xAAA")
    snapshot = Onchain::Snapshot.new(assets: [ native, token_asset ], movements: [])

    assert_equal native, snapshot.find_asset(kind: "native")
    assert_equal token_asset, snapshot.find_asset(kind: OnchainTestHelper::FAKE_TOKEN_KIND, contract: "0xaaa")
    assert_nil snapshot.find_asset(kind: OnchainTestHelper::FAKE_TOKEN_KIND, contract: "0xccc")
  end

  test "empty snapshot has no assets or movements" do
    assert_empty Onchain::Snapshot.empty.assets
    assert_empty Onchain::Snapshot.empty.movements
  end
end
