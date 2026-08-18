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

    # Assets identified by their address alone.
    NATIVE_KIND = "native"

    # Token identity models that the schema has a partial unique index for
    # (see CreateOnchainWalletItemsAndAccounts). Registering a chain whose
    # tokens don't fit one of these would silently lose DB-level uniqueness,
    # so `register` refuses it.
    INDEXED_TOKEN_KINDS = %w[erc20 spl].freeze

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

      def token_asset(symbol:, name:, decimals:, quantity:, contract:)
        raise Error, "#{key} does not support tokens" unless supports_tokens?

        Onchain::Asset.token(
          kind: token_kind,
          symbol: symbol,
          name: name,
          decimals: decimals,
          quantity: quantity,
          contract: contract
        )
      end
    end

    BITCOIN = "bitcoin"

    BUILTIN = [
      Definition.new(
        key: BITCOIN,
        native: NativeAsset.new(symbol: "BTC", name: "Bitcoin", decimals: 8),
        token_kind: nil,
        adapter_class_name: "Onchain::BitcoinAdapter",
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
