require "test_helper"
require "support/bitcoin_wallet_test_helper"

class BitcoinWalletAccount::SnapshotTest < ActiveSupport::TestCase
  include BitcoinWalletTestHelper

  setup do
    @wallet = build_bitcoin_wallet
    @provider = FakeProvider.new
    [ RECEIVE, CHANGE ].each { |address| @wallet.bitcoin_wallet_addresses.create!(address: address) }
  end

  test "aggregates confirmed balances to one satoshi" do
    @provider.fund(RECEIVE, 1)
    @provider.fund(CHANGE, 2)
    snapshot = BitcoinWalletAccount::Snapshot.new(@wallet, provider: @provider).fetch
    assert_equal 3, snapshot.balance_sats
  end

  test "deduplicates a pending internal transfer and counts only its fee" do
    @provider.fund(RECEIVE, 100_000)
    tx = bitcoin_transaction(inputs: [ [ RECEIVE, 100_000 ] ], outputs: [ [ CHANGE, 99_000 ] ], confirmed: false)
    @provider.transactions = { RECEIVE => [ tx ], CHANGE => [ tx ] }
    snapshot = BitcoinWalletAccount::Snapshot.new(@wallet, provider: @provider).fetch
    assert_equal 99_000, snapshot.balance_sats
    assert_equal 1, snapshot.transactions.size
  end

  test "a batched exchange withdrawal only credits this wallet's output" do
    outputs = 15.times.map { |index| [ "other#{index}", 10_000 ] } + [ [ RECEIVE, 1_234_567 ] ]
    tx = bitcoin_transaction(inputs: [ [ "exchange", 10_000_000 ] ], outputs: outputs, confirmed: false)
    @provider.transactions[RECEIVE] = [ tx ]
    assert_equal 1_234_567, BitcoinWalletAccount::Snapshot.new(@wallet, provider: @provider).fetch.balance_sats
  end

  test "pending change belongs to the wallet even before its HD address is marked used" do
    source = @wallet.bitcoin_wallet_sources.create!(kind: "bip84", extended_public_key: ZPUB, receive_address: RECEIVE)
    @wallet.bitcoin_wallet_addresses.update_all(bitcoin_wallet_source_id: source.id)
    @wallet.bitcoin_wallet_addresses.find_by!(address: RECEIVE).update!(used: true)
    @provider.fund(RECEIVE, 100_000)
    tx = bitcoin_transaction(inputs: [ [ RECEIVE, 100_000 ] ],
      outputs: [ [ "recipient", 40_000 ], [ CHANGE, 59_000 ] ], confirmed: false)
    @provider.transactions[RECEIVE] = [ tx ]

    snapshot = BitcoinWalletAccount::Snapshot.new(@wallet, provider: @provider).fetch

    assert_equal 59_000, snapshot.balance_sats
    assert_equal [ RECEIVE, CHANGE ], @provider.reads
    assert_equal(-41_000, BitcoinWalletAccount::Snapshot.net_sats(tx, @wallet.bitcoin_wallet_addresses.pluck(:address).to_set))
  end

  test "follows pending child spends through newly funded lookahead addresses" do
    source = @wallet.bitcoin_wallet_sources.create!(kind: "bip84", extended_public_key: ZPUB, receive_address: RECEIVE)
    @wallet.bitcoin_wallet_addresses.update_all(bitcoin_wallet_source_id: source.id)
    @wallet.bitcoin_wallet_addresses.find_by!(address: RECEIVE).update!(used: true)
    @wallet.bitcoin_wallet_addresses.create!(address: SECOND, bitcoin_wallet_source: source)
    @provider.fund(RECEIVE, 100_000)
    parent = bitcoin_transaction(inputs: [ [ RECEIVE, 100_000 ] ], outputs: [ [ CHANGE, 99_000 ] ], confirmed: false)
    child = bitcoin_transaction(id: "c" * 64, inputs: [ [ CHANGE, 99_000 ] ], outputs: [ [ SECOND, 98_000 ] ], confirmed: false)
    grandchild = bitcoin_transaction(id: "d" * 64, inputs: [ [ SECOND, 98_000 ] ], outputs: [ [ "recipient", 97_000 ] ], confirmed: false)
    child["vin"].first.merge!("txid" => parent["txid"], "vout" => 0)
    grandchild["vin"].first.merge!("txid" => child["txid"], "vout" => 0)
    @provider.transactions = { RECEIVE => [ parent ], CHANGE => [ parent, child ], SECOND => [ child, grandchild ] }

    snapshot = BitcoinWalletAccount::Snapshot.new(@wallet, provider: @provider).fetch

    assert_equal 0, snapshot.balance_sats
    assert_equal 3, snapshot.transactions.size
    assert_equal [ RECEIVE, CHANGE, SECOND ], @provider.reads
  end

  test "a changed chain tip prevents publication" do
    @provider.stubs(:tip_hash).returns("old", "new")
    assert_raises(BitcoinWalletAccount::Snapshot::ChangedTip) do
      BitcoinWalletAccount::Snapshot.new(@wallet, provider: @provider).fetch
    end
  end

  test "incompatible RBF observations cannot be summed into a balance" do
    first = bitcoin_transaction(id: "c" * 64, inputs: [ [ RECEIVE, 100_000 ] ], outputs: [ [ CHANGE, 99_000 ] ], confirmed: false)
    second = bitcoin_transaction(id: "d" * 64, inputs: [ [ RECEIVE, 100_000 ] ], outputs: [ [ CHANGE, 98_000 ] ], confirmed: false)
    [ first, second ].each { |tx| tx["vin"].first.merge!("txid" => "f" * 64, "vout" => 0) }
    @provider.transactions = { RECEIVE => [ first ], CHANGE => [ second ] }
    assert_raises(BitcoinWalletAccount::Snapshot::IncompleteMempool) do
      BitcoinWalletAccount::Snapshot.new(@wallet, provider: @provider).fetch
    end
  end

  test "unused HD lookahead is not reread inside the stable-tip window" do
    source = @wallet.bitcoin_wallet_sources.create!(kind: "bip84", extended_public_key: ZPUB, receive_address: RECEIVE)
    @wallet.bitcoin_wallet_addresses.update_all(bitcoin_wallet_source_id: source.id)
    BitcoinWalletAddress.insert_all!(2000.times.map do |index|
      { bitcoin_wallet_account_id: @wallet.id, bitcoin_wallet_source_id: source.id,
        family_id: @wallet.family.id, address: "unused-lookahead-#{index}", used: false }
    end)
    BitcoinWalletAccount::Snapshot.new(@wallet, provider: @provider).fetch
    assert_equal [ RECEIVE ], @provider.reads
  end
end
