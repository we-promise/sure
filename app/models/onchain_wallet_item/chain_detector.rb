# frozen_string_literal: true

# Works out which chain an address belongs to.
#
# Address formats are not unique to a chain: one 0x address is valid on every
# EVM network and holds different balances on each, and Bitcoin's Base58 shape
# overlaps Solana's. So candidates come from the address format, and when there
# is more than one, each candidate is asked whether the address is worth tracking
# there — one bounded request per chain, never transfer history.
#
# When several chains answer yes, or none does, the user chooses. Silently
# keeping the first match would link the wrong network and look like a sync bug
# later.
class OnchainWalletItem::ChainDetector
  Result = Data.define(:chain, :candidates, :detected_keys) do
    def resolved?
      chain.present?
    end

    def unrecognized?
      candidates.empty?
    end

    def ambiguous?
      chain.blank? && candidates.any?
    end

    def detected?(candidate)
      detected_keys.include?(candidate.key)
    end
  end

  def initialize(onchain_wallet_item, address)
    @onchain_wallet_item = onchain_wallet_item
    @address = address
  end

  def detect
    candidates = onchain_wallet_item.matching_chain_adapters(address)
    return Result.new(chain: nil, candidates: [], detected_keys: []) if candidates.empty?

    definitions = candidates.map(&:first)
    return Result.new(chain: definitions.first.key, candidates: definitions, detected_keys: []) if candidates.one?

    detected = candidates.select { |_definition, adapter| adapter.has_activity?(address) }.map { |definition, _| definition }

    Result.new(
      chain: detected.one? ? detected.first.key : nil,
      candidates: definitions,
      detected_keys: detected.map(&:key)
    )
  end

  private
    attr_reader :onchain_wallet_item, :address
end
