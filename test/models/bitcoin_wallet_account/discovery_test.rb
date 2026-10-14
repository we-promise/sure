require "test_helper"
require "support/bitcoin_wallet_test_helper"

class BitcoinWalletAccount::DiscoveryTest < ActiveSupport::TestCase
  include BitcoinWalletTestHelper

  setup do
    @wallet = build_bitcoin_wallet
    @provider = FakeProvider.new
  end

  test "discovers both branches including spent addresses and a trailing gap" do
    @wallet.bitcoin_wallet_sources.create!(kind: "bip84", extended_public_key: ZPUB, receive_address: RECEIVE)
    @provider.fund(RECEIVE, 0)
    @provider.fund(CHANGE, 1)
    assert BitcoinWalletAccount::Discovery.new(@wallet, provider: @provider).perform
    assert @wallet.bitcoin_wallet_addresses.find_by!(address: RECEIVE).used?
    assert @wallet.bitcoin_wallet_addresses.exists?(address: CHANGE)
    assert_equal 42, @wallet.bitcoin_wallet_addresses.count
  end

  test "manual and derived addresses are counted once" do
    manual_bitcoin_source(@wallet)
    @wallet.bitcoin_wallet_sources.create!(kind: "bip84", extended_public_key: ZPUB, receive_address: RECEIVE)
    assert BitcoinWalletAccount::Discovery.new(@wallet, provider: @provider).perform
    assert_equal 1, @wallet.bitcoin_wallet_addresses.where(address: RECEIVE).count
  end

  test "an unrelated manual address does not validate the wrong xpub" do
    manual_bitcoin_source(@wallet, "1BoatSLRHtKNngkdXEeobR76b53LETtpyT")
    @wallet.bitcoin_wallet_sources.create!(kind: "bip84", extended_public_key: ZPUB,
      receive_address: "1BoatSLRHtKNngkdXEeobR76b53LETtpyT")
    assert_raises(BitcoinWalletAccount::Discovery::AddressMismatch) do
      BitcoinWalletAccount::Discovery.new(@wallet, provider: @provider).perform
    end
  end

  test "bounds work and resumes at the saved cursor" do
    source = @wallet.bitcoin_wallet_sources.create!(kind: "bip84", extended_public_key: ZPUB,
      receive_address: RECEIVE, gap_limit: 1000)
    Onchain::BitcoinPublicKey.any_instance.stubs(:address).returns(RECEIVE)
    refute BitcoinWalletAccount::Discovery.new(@wallet, provider: @provider).perform
    assert_equal 200, @provider.reads.size
    assert_equal 200, source.reload.discovery.dig("0", "index")
    refute BitcoinWalletAccount::Discovery.new(@wallet, provider: @provider).perform
    assert_equal 400, source.reload.discovery.dig("0", "index")
  end

  test "routine rescans probe a standard window and the full gap once a day" do
    @wallet.bitcoin_wallet_sources.create!(kind: "bip84", extended_public_key: ZPUB,
      receive_address: RECEIVE, gap_limit: 50)
    @provider.fund(RECEIVE, 1)
    assert BitcoinWalletAccount::Discovery.new(@wallet, provider: @provider).perform

    rescan = lambda do
      @wallet.reload.restart_discovery!
      @provider.reads.clear
      assert BitcoinWalletAccount::Discovery.new(@wallet, provider: @provider).perform
      @provider.reads.size
    end

    assert_equal 100, rescan.call
    assert_equal 2 * BitcoinWalletAccount::ROUTINE_LOOKAHEAD, rescan.call
    travel 25.hours do
      assert_equal 100, rescan.call
    end
  end

  test "a scan does not restore a source removed during its reads" do
    source = @wallet.bitcoin_wallet_sources.create!(kind: "bip84", extended_public_key: ZPUB, receive_address: RECEIVE)
    removed = BitcoinWalletSource.find(source.id)
    @provider.define_singleton_method(:get_address) do |address|
      removed.destroy! if reads.empty?
      super(address)
    end
    BitcoinWalletAccount::Discovery.new(@wallet, provider: @provider).perform
    assert_empty @wallet.bitcoin_wallet_addresses.reload
  end

  test "a scan does not overwrite a checkpoint reset during its reads" do
    source = @wallet.bitcoin_wallet_sources.create!(kind: "bip84", extended_public_key: ZPUB, receive_address: RECEIVE)
    reset = { "0" => { "index" => 0, "gap" => 0 }, "1" => { "index" => 0, "gap" => 0 } }
    @provider.define_singleton_method(:get_address) do |address|
      BitcoinWalletSource.where(id: source.id).update_all(discovery: reset) if reads.empty?
      super(address)
    end
    refute BitcoinWalletAccount::Discovery.new(@wallet, provider: @provider).perform
    assert_equal reset, source.reload.discovery
  end

  test "an address tracked by another account in this family is rejected" do
    other_account = accounts(:crypto).dup
    other_account.name = "Other wallet"
    other_account.save!
    other = build_bitcoin_wallet(account: other_account)
    manual_bitcoin_source(other)
    BitcoinWalletAccount::Discovery.new(other, provider: @provider).perform
    manual_bitcoin_source(@wallet)
    assert_raises(BitcoinWalletAccount::Discovery::Conflict) do
      BitcoinWalletAccount::Discovery.new(@wallet, provider: @provider).perform
    end
  end

  test "an unlinked legacy address does not reserve the address" do
    @wallet.onchain_wallet_item.onchain_wallet_accounts.create!(chain: Onchain::Chains::BITCOIN,
      wallet_address: RECEIVE, asset_kind: "native", symbol: "BTC", name: "Bitcoin",
      decimals: 8, quantity: "0.1", currency: "USD")
    manual_bitcoin_source(@wallet)
    assert BitcoinWalletAccount::Discovery.new(@wallet, provider: @provider).perform
    assert @wallet.bitcoin_wallet_addresses.exists?(address: RECEIVE)
  end

  test "a linked legacy address blocks grouped ownership" do
    legacy = @wallet.onchain_wallet_item.onchain_wallet_accounts.create!(chain: Onchain::Chains::BITCOIN,
      wallet_address: RECEIVE, asset_kind: "native", symbol: "BTC", name: "Bitcoin",
      decimals: 8, quantity: "0.1", currency: "USD")
    legacy.ensure_account_provider!(@wallet.account)
    manual_bitcoin_source(@wallet)
    assert_raises(BitcoinWalletAccount::Discovery::Conflict) do
      BitcoinWalletAccount::Discovery.new(@wallet, provider: @provider).perform
    end
    assert_empty @wallet.bitcoin_wallet_addresses.reload
  end
end
