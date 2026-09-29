# frozen_string_literal: true

# Avalanche's P-Chain, read from a single address. This is where AVAX
# staking/delegation actually happens — the P-Chain is not EVM-compatible and
# shares nothing with Onchain::EvmAdapter (which only ever sees the separate
# C-Chain). See Provider::AvalanchePChain for the API this reads.
#
# P-Chain has no token concept in this app's asset model (no erc20/spl
# equivalent), so — like Bitcoin — only a native AVAX quantity is reported:
# everything held in P-Chain UTXOs (`balance`) plus everything currently
# bonded in an active validation/delegation (`staked`), so a delegator's total
# shows correctly whether or not their stake is active right now.
#
# History: Avalanche has no keyless, stable REST indexer for P-Chain
# transactions equivalent to mempool.space/Blockscout, so movements are not
# implemented — this adapter reports balance only and marks history as
# truncated, the same degrade path Onchain::ChainAdapter#best_effort_movements
# exists for.
class Onchain::AvalanchePChainAdapter
  include Onchain::ChainAdapter

  NANO_AVAX_PER_AVAX = 1_000_000_000.to_d

  # Avalanche's own bech32 variant: "P-avax1" + a 20-byte hash. Same relaxed
  # length range as Onchain::BitcoinAdapter's BECH32_PATTERN (checksum isn't
  # verified here either) and the same excluded characters (bech32 drops
  # 1, b, i, o from the data part).
  ADDRESS_PATTERN = /\AP-avax1[ac-hj-np-z02-9]{20,60}\z/i

  def initialize(credentials: {})
    @credentials = credentials
  end

  def valid_address?(address)
    ADDRESS_PATTERN.match?(address.to_s.strip)
  end

  # Bech32 is case-insensitive and canonically lowercase.
  def canonical_address(address)
    address.to_s.strip.downcase
  end

  def fetch_snapshot(address)
    raise Onchain::Chains::Error, "Invalid Avalanche P-Chain address" unless valid_address?(address)

    wrap_provider_errors do
      quantity = total_avax(address)

      Onchain::Snapshot.new(
        assets: [ definition.native_asset(quantity: quantity) ],
        movements: [],
        history_truncated: true
      )
    end
  end

  def provider_error_classes
    [ [], Provider::AvalanchePChain::Error ]
  end

  private
    attr_reader :credentials

    def definition
      Onchain::Chains.find!("avalanche_p")
    end

    def provider
      @provider ||= Provider::AvalanchePChain.new
    end

    # `balance` already excludes anything actively bonded (see provider
    # file), so summing it with `staked` double-counts nothing.
    def total_avax(address)
      balance = provider.get_balance(address)["balance"].to_d
      staked = provider.get_stake(address)["staked"].to_d

      (balance + staked) / NANO_AVAX_PER_AVAX
    end
end
