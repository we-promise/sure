# frozen_string_literal: true

# The single source of truth for which chains exist.
#
# Address validation, native asset metadata and which adapter to instantiate
# all live here. No other file in app/ may name a chain: everything downstream
# receives an Onchain::Snapshot and works the same for every chain. Adding a
# chain means adding one entry to BUILTIN and one adapter.
module Onchain
  module Chains
    Error = Class.new(StandardError)
    UnknownChainError = Class.new(Error)
    # A chain's data source refused or could not answer. Adapters translate
    # whatever their explorer raises into these, so callers — the controller
    # above all — never need to know one chain's error types from another's.
    UnreachableError = Class.new(Error)
    RateLimitedError = Class.new(Error)

    # Assets identified by their address alone.
    NATIVE_KIND = "native"

    # Token identity models that the schema has a partial unique index for
    # (see CreateOnchainWalletItemsAndAccounts). Registering a chain whose
    # tokens don't fit one of these would silently lose DB-level uniqueness,
    # so `register` refuses it.
    INDEXED_TOKEN_KINDS = %w[erc20 spl].freeze

    # Token kinds whose contract identifier carries no case: an EVM contract is
    # hex, so 0xAbC and 0xabc are one token. An SPL mint is a Base58 public key
    # where case is part of the value — downcasing one corrupts it, and two
    # distinct mints can collide once folded.
    CASE_INSENSITIVE_CONTRACT_KINDS = %w[erc20].freeze

    NativeAsset = Data.define(:symbol, :name, :decimals)

    Definition = Data.define(:key, :native, :token_kind, :adapter_class_name, :adapter_options) do
      def label
        I18n.t("onchain.chains.#{key}", default: key.to_s.titleize)
      end

      def adapter(credentials: {})
        adapter_class_name.constantize.new(**adapter_options, credentials: credentials)
      end

      def supports_tokens?
        token_kind.present?
      end

      def asset_kinds
        [ NATIVE_KIND, token_kind ].compact
      end

      def native_asset(quantity:)
        Onchain::Asset.native(
          symbol: native.symbol,
          name: native.name,
          decimals: native.decimals,
          quantity: quantity
        )
      end

      def token_asset(symbol:, name:, decimals:, quantity:, contract:, notable: false)
        raise Error, "#{key} does not support tokens" unless supports_tokens?

        Onchain::Asset.token(
          kind: token_kind,
          symbol: symbol,
          name: name,
          decimals: decimals,
          quantity: quantity,
          contract: contract,
          notable: notable
        )
      end
    end

    BITCOIN = "bitcoin"

    ETHEREUM = "ethereum"

    # Every EVM network shares one adapter; what makes them different is data.
    # `etherscan_chain_id` is set only where a family-supplied Etherscan key is
    # accepted, which today is Ethereum alone.
    EVM = [
      { key: ETHEREUM, symbol: "ETH",  name: "Ethereum", explorer_url: "https://eth.blockscout.com",      etherscan_chain_id: "1" },
      { key: "base",     symbol: "ETH",  name: "Ethereum", explorer_url: "https://base.blockscout.com" },
      { key: "arbitrum", symbol: "ETH",  name: "Ethereum", explorer_url: "https://arbitrum.blockscout.com" },
      { key: "optimism", symbol: "ETH",  name: "Ethereum", explorer_url: "https://optimism.blockscout.com" },
      { key: "polygon",  symbol: "POL",  name: "Polygon",  explorer_url: "https://polygon.blockscout.com" },
      { key: "gnosis",   symbol: "XDAI", name: "xDai",     explorer_url: "https://gnosis.blockscout.com" }
    ].freeze

    SOLANA = "solana"

    BUILTIN = [
      Definition.new(
        key: BITCOIN,
        native: NativeAsset.new(symbol: "BTC", name: "Bitcoin", decimals: 8),
        token_kind: nil,
        adapter_class_name: "Onchain::BitcoinAdapter",
        adapter_options: {}
      ),
      *EVM.map do |evm|
        Definition.new(
          key: evm[:key],
          native: NativeAsset.new(symbol: evm[:symbol], name: evm[:name], decimals: 18),
          token_kind: "erc20",
          adapter_class_name: "Onchain::EvmAdapter",
          adapter_options: {
            chain: evm[:key],
            explorer_url: evm[:explorer_url],
            etherscan_chain_id: evm[:etherscan_chain_id]
          }.compact
        )
      end,
      Definition.new(
        key: SOLANA,
        native: NativeAsset.new(symbol: "SOL", name: "Solana", decimals: 9),
        token_kind: "spl",
        adapter_class_name: "Onchain::SolanaAdapter",
        adapter_options: {}
      )
    ].freeze

    class << self
      def all
        registry.values
      end

      def keys
        registry.keys
      end

      def find(key)
        registry[key.to_s]
      end

      def find!(key)
        find(key) || raise(UnknownChainError, "Unknown chain: #{key}")
      end

      def exists?(key)
        find(key).present?
      end

      def adapter_for(key, credentials: {})
        find!(key).adapter(credentials: credentials)
      end

      def valid_address?(key, address)
        definition = find(key)
        return false unless definition

        definition.adapter.valid_address?(address)
      end

      def contract_case_sensitive?(asset_kind)
        !CASE_INSENSITIVE_CONTRACT_KINDS.include?(asset_kind.to_s)
      end

      # The canonical spelling of an address on a chain, or the input stripped when
      # the chain is unknown.
      def canonical_address(key, address)
        definition = find(key)
        return address.to_s.strip unless definition

        definition.adapter.canonical_address(address)
      end

      # Chains whose address format accepts this string. A 0x address matches
      # every EVM network, which is what makes chain detection necessary.
      def matching(address)
        all.select { |definition| definition.adapter.valid_address?(address) }
      end

      # Test seam for the fake chain, and the hook a future plugin would use.
      def register(definition)
        unless definition.token_kind.nil? || INDEXED_TOKEN_KINDS.include?(definition.token_kind)
          raise Error, "token_kind #{definition.token_kind.inspect} has no unique index"
        end

        registry[definition.key.to_s] = definition
      end

      def unregister(key)
        registry.delete(key.to_s)
      end

      private
        def registry
          @registry ||= BUILTIN.index_by { |definition| definition.key.to_s }
        end
    end
  end
end
