# frozen_string_literal: true

# One asset held by an address on a chain, normalised so that nothing
# downstream of a chain adapter needs to know which chain produced it.
#
# `kind` is the asset identity model, not the chain: "native" assets are
# identified by their address alone, token kinds ("erc20", "spl") by their
# contract/mint. It is what the partial unique indexes on
# onchain_wallet_accounts key off.
module Onchain
  Asset = Data.define(:kind, :symbol, :name, :decimals, :quantity, :contract, :notable) do
    # `notable` means the data source treats this as a real asset the holder
    # probably cares about: a priced holding worth more than dust on an EVM
    # indexer, a place on Solana's verified token list. Anyone can mint a token
    # with a plausible three-letter symbol, so the symbol itself says nothing —
    # this is what separates an asset from an airdrop.
    def initialize(kind:, symbol:, name:, decimals:, quantity:, contract:, notable: false)
      super
    end

    def self.native(symbol:, name:, decimals:, quantity:)
      new(
        kind: Onchain::Chains::NATIVE_KIND,
        symbol: symbol,
        name: name,
        decimals: decimals,
        quantity: quantity,
        contract: nil,
        notable: true
      )
    end

    def self.token(kind:, symbol:, name:, decimals:, quantity:, contract:, notable: false)
      new(
        kind: kind,
        symbol: symbol,
        name: name,
        decimals: decimals,
        quantity: quantity,
        contract: contract,
        notable: notable
      )
    end

    def notable?
      notable == true
    end

    def native?
      kind == Onchain::Chains::NATIVE_KIND
    end

    # Contracts are case-insensitive on every chain we support, so identity
    # comparisons and the DB uniqueness key both use the downcased form.
    def contract_key
      contract.presence&.downcase
    end
  end
end
