# frozen_string_literal: true

require "test_helper"

class OnchainWalletItemTest < ActiveSupport::TestCase
  include OnchainTestHelper, ActiveJob::TestHelper

  setup do
    register_fake_chain!
    @family = families(:dylan_family)
    @item = create_onchain_wallet_item(family: @family)
  end

  teardown do
    unregister_fake_chain!
  end

  test "is syncable without credentials because chains are readable keyless" do
    assert @item.credentials_configured?
  end

  test "wallet_keys lists each tracked address once" do
    create_onchain_wallet_account(item: @item)
    create_onchain_wallet_account(item: @item, asset: fake_token_asset(contract: "0xaaa"))
    create_onchain_wallet_account(item: @item, address: OnchainTestHelper::FAKE_ADDRESS_ALT)

    assert_equal(
      [
        [ OnchainTestHelper::FAKE_CHAIN, OnchainTestHelper::FAKE_ADDRESS ],
        [ OnchainTestHelper::FAKE_CHAIN, OnchainTestHelper::FAKE_ADDRESS_ALT ]
      ],
      @item.wallet_keys.sort
    )
  end

  test "strips a blank explorer credential down to nil" do
    @item.update!(etherscan_api_key: "  ")
    assert_nil @item.reload.etherscan_api_key

    @item.update!(etherscan_api_key: " abc ")
    assert_equal "abc", @item.reload.etherscan_api_key
  end

  test "passes the explorer credential to chain adapters" do
    @item.update!(etherscan_api_key: "abc")

    assert_equal "abc", @item.chain_adapter(OnchainTestHelper::FAKE_CHAIN).credentials[:etherscan_api_key]
  end

  test "matching_chain_adapters only returns chains that accept the address" do
    matches = @item.matching_chain_adapters(OnchainTestHelper::FAKE_ADDRESS)

    assert_equal [ OnchainTestHelper::FAKE_CHAIN ], matches.map { |definition, _adapter| definition.key }
    assert_empty @item.matching_chain_adapters("nope")
  end

  test "destroy_later flags the item and enqueues destruction" do
    assert_enqueued_with(job: DestroyJob) do
      @item.destroy_later
    end

    assert @item.reload.scheduled_for_deletion
    assert_not_includes OnchainWalletItem.active, @item
  end

  test "family only reports linked addresses it actually tracks" do
    assert_not @family.onchain_address_linked?(OnchainTestHelper::FAKE_CHAIN, OnchainTestHelper::FAKE_ADDRESS)

    link_onchain_wallet_account!(create_onchain_wallet_account(item: @item))

    assert @family.onchain_address_linked?(OnchainTestHelper::FAKE_CHAIN, OnchainTestHelper::FAKE_ADDRESS)
    assert_not @family.onchain_address_linked?(OnchainTestHelper::FAKE_CHAIN, OnchainTestHelper::FAKE_ADDRESS_ALT)
  end

  test "an address whose row tracks nothing is free to be added again" do
    onchain_account = create_onchain_wallet_account(item: @item)

    # No account behind it: it syncs nothing and appears nowhere, so reporting
    # the address as taken would refuse it with nothing to show the user.
    assert_not @family.onchain_address_linked?(OnchainTestHelper::FAKE_CHAIN, OnchainTestHelper::FAKE_ADDRESS)
    assert OnchainWalletAccount.exists?(onchain_account.id)
  end
end
