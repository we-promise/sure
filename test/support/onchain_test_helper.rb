# frozen_string_literal: true

# A chain that does not exist, so the chain-agnostic half of the on-chain wallet
# feature (registry, importer, processor, syncer, controller) can be tested
# without any real network behaviour leaking in. Real chains get their own test
# files so a failure names a chain.
module OnchainTestHelper
  FAKE_CHAIN = "fakechain"
  FAKE_TOKEN_KIND = "erc20"
  FAKE_ADDRESS = "fake1qqqqqqqqqqqqqqqqqqqq"
  FAKE_ADDRESS_ALT = "fake1zzzzzzzzzzzzzzzzzzzz"

  # Returns whatever snapshot the test told it to return, and records every call
  # so tests can assert on request counts.
  class FakeAdapter
    include Onchain::ChainAdapter

    ADDRESS_PATTERN = /\Afake1[a-z0-9]{4,}\z/

    class << self
      attr_accessor :snapshots, :activity, :error
      attr_reader :snapshot_calls, :activity_calls

      def reset!
        @snapshots = {}
        @activity = {}
        @error = nil
        @snapshot_calls = []
        @activity_calls = []
      end

      def record_snapshot_call(address)
        @snapshot_calls << address
      end

      def record_activity_call(address)
        @activity_calls << address
      end
    end

    reset!

    attr_reader :credentials

    def initialize(credentials: {})
      @credentials = credentials
    end

    def valid_address?(address)
      address.to_s.match?(ADDRESS_PATTERN)
    end

    def fetch_snapshot(address)
      self.class.record_snapshot_call(address)
      raise self.class.error if self.class.error

      self.class.snapshots.fetch(address, Onchain::Snapshot.empty)
    end

    def has_activity?(address)
      self.class.record_activity_call(address)
      self.class.activity.fetch(address, super)
    end
  end

  def register_fake_chain!(token_kind: FAKE_TOKEN_KIND)
    FakeAdapter.reset!

    Onchain::Chains.register(
      Onchain::Chains::Definition.new(
        key: FAKE_CHAIN,
        native: Onchain::Chains::NativeAsset.new(symbol: "FAKE", name: "Fake Coin", decimals: 8),
        token_kind: token_kind,
        adapter_class_name: "OnchainTestHelper::FakeAdapter",
        adapter_options: {}
      )
    )
  end

  def unregister_fake_chain!
    Onchain::Chains.unregister(FAKE_CHAIN)
    FakeAdapter.reset!
  end

  def fake_chain
    Onchain::Chains.find!(FAKE_CHAIN)
  end

  def stub_fake_snapshot(address, snapshot)
    FakeAdapter.snapshots[address] = snapshot
  end

  def fake_native_asset(quantity: 1.5)
    fake_chain.native_asset(quantity: BigDecimal(quantity.to_s))
  end

  def fake_token_asset(symbol: "FUSD", contract: "0xabc", quantity: 100, decimals: 6, name: nil)
    fake_chain.token_asset(
      symbol: symbol,
      name: name || symbol,
      decimals: decimals,
      quantity: BigDecimal(quantity.to_s),
      contract: contract
    )
  end

  def fake_movement(external_id:, symbol: "FAKE", contract: nil, amount: 1, timestamp: nil)
    Onchain::Movement.new(
      external_id: external_id,
      symbol: symbol,
      contract: contract,
      amount: BigDecimal(amount.to_s),
      timestamp: timestamp || 3.days.ago.to_date
    )
  end

  def create_onchain_wallet_item(family:, **attrs)
    OnchainWalletItem.create!({ family: family, name: "Wallets" }.merge(attrs))
  end

  # Links a tracked asset to a real Sure account, the way the linking flow does.
  def link_onchain_wallet_account!(onchain_wallet_account)
    account = Account.create_from_onchain_wallet_account(onchain_wallet_account)
    onchain_wallet_account.ensure_account_provider!(account)
    onchain_wallet_account.reload
    account
  end

  def create_onchain_wallet_account(item:, asset: nil, chain: FAKE_CHAIN, address: FAKE_ADDRESS, **attrs)
    asset ||= fake_native_asset
    item.onchain_wallet_accounts.create!({
      chain: chain,
      wallet_address: address,
      asset_kind: asset.kind,
      contract_address: asset.contract,
      symbol: asset.symbol,
      name: asset.name,
      decimals: asset.decimals,
      quantity: asset.quantity,
      currency: item.family.currency
    }.merge(attrs))
  end
end
