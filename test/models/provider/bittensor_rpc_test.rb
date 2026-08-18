# frozen_string_literal: true

require "test_helper"

class Provider::BittensorRpcTest < ActiveSupport::TestCase
  COLDKEY = "5FTbV11nyHgQLjsgLAQHvpNEoVSdeFuLajwYiZt1Lf7dK4Ds"

  test "validates SS58 Bittensor coldkeys and rejects other formats" do
    provider = Provider::BittensorRpc.new

    assert provider.valid_address?(COLDKEY)
    assert_not provider.valid_address?("0xf5c6b8e6eb92e560a33f6fd6d86a1c734d2d7840")
    assert_not provider.valid_address?("EnQtaNYKgnbSaZ1ekZYXVbYnau2ZCNda3NzbbnWCna7B")
    assert_not provider.valid_address?("not-a-wallet")
  end

  test "get_native_balance reads free rao from System.Account storage" do
    provider = Provider::BittensorRpc.new
    free_rao = 47_156_172
    # 4×u32 header + free u128 LE + reserved/frozen padding
    storage_bytes = ("\x00" * 16) + [ free_rao & ((1 << 64) - 1), 0 ].pack("Q<*") + ("\x00" * 24)
    provider.stubs(:rpc).with("state_getStorage", anything).returns("0x#{storage_bytes.unpack1('H*')}")

    assert_equal free_rao.to_s, provider.get_native_balance(COLDKEY)
  end

  test "substrate codec blake2b-128 and twox128 match known vectors" do
    codec = Provider::BittensorRpc::SubstrateCodec

    assert_equal "cae66941d9efbd404e4d88758ea67670", codec.blake2b("", 16).unpack1("H*")
    assert_equal "cf4ab791c62b8d2b2109c90275287816", codec.blake2b("abc", 16).unpack1("H*")
    assert_equal "26aa394eea5630e07c48ae0c9558cef7", codec.twox128("System").unpack1("H*")
    assert_equal "b99d880ec681799c0cf30e8886371da9", codec.twox128("Account").unpack1("H*")
  end

  test "detect_chain_type prefers bittensor SS58 over solana base58" do
    assert_equal :bittensor, OnchainWalletAccount.detect_chain_type(COLDKEY)
    assert_equal :solana, OnchainWalletAccount.detect_chain_type("EnQtaNYKgnbSaZ1ekZYXVbYnau2ZCNda3NzbbnWCna7B")
  end
end
