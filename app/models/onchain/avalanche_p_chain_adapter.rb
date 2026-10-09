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
  #
  # "P-" is Avalanche's own chain-context prefix, not part of the address's
  # cryptographic data - the same bech32 payload is shared with the X-Chain
  # (prefixed "X-" there), so many wallets/explorers display or export the
  # bare "avax1..." form with no chain prefix at all. The prefix is optional
  # here for exactly that reason; canonical_address below always adds it
  # back, since the provider's RPC calls require it to know which chain to
  # query, and dedupe needs one spelling regardless of how a user pastes it.
  ADDRESS_PATTERN = /\A(?:P-)?avax1[ac-hj-np-z02-9]{20,60}\z/i

  def initialize(credentials: {})
    @credentials = credentials
  end

  def valid_address?(address)
    ADDRESS_PATTERN.match?(address.to_s.strip)
  end

  # Bech32 is case-insensitive and canonically lowercase, but the "P-"
  # chain-context prefix is not part of the bech32 payload - it is Avalanche's
  # own chain-alias lookup, and the node only registers the alias "P"
  # (uppercase), not "p". A fully-lowercased "p-avax1..." is rejected by the
  # node's RPC with "there is no ID with alias: p", which this app's error
  # handling can't tell apart from the node being genuinely unreachable - so
  # getting this wrong here surfaces as a misleading "could not be reached"
  # for every single address. The prefix is restored/normalized to uppercase
  # "P-" regardless of input casing; only the bech32 payload after it is
  # lowercased.
  def canonical_address(address)
    value = address.to_s.strip.downcase
    bech32_payload = value.delete_prefix("p-")
    "P-#{bech32_payload}"
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
