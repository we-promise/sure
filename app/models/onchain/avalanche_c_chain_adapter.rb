# frozen_string_literal: true

# Avalanche's C-Chain: standard EVM, standard 0x addresses, where regular
# AVAX/token balances and transfers actually live — separate from the
# P-Chain (staking/delegation only, bech32 "P-avax1…" addresses, see
# Onchain::AvalanchePChainAdapter). Not built on Onchain::EvmAdapter: that
# adapter is hard-wired to a Blockscout-compatible indexer for balances, and
# no such instance exists for Avalanche C-Chain (see Provider::AvalancheCChain
# for the chain-directory check). This reads Avalanche's own public RPC
# directly instead.
#
# Same degrade as Onchain::BitcoinAdapter and Onchain::AvalanchePChainAdapter:
# no free, keyless indexer means no ERC-20 token enumeration and no transfer
# history, only a native balance. `token_kind: nil` in the registry entry
# reflects that — this chain has no token concept in this app's asset model,
# same as Bitcoin, the P-Chain, and the staking-only adapters.
class Onchain::AvalancheCChainAdapter
  include Onchain::ChainAdapter

  WEI_PER_AVAX = (10**18).to_d

  ADDRESS_PATTERN = Onchain::EvmAdapter::ADDRESS_PATTERN

  def initialize(credentials: {})
    @credentials = credentials
  end

  def valid_address?(address)
    ADDRESS_PATTERN.match?(address.to_s.strip)
  end

  # Hex is hex: the mixed case of a checksummed address carries no identity,
  # matching Onchain::EvmAdapter#canonical_address for every other EVM chain.
  def canonical_address(address)
    address.to_s.strip.downcase
  end

  # Every EVM network shares the 0x shape, so without this override the default
  # (a well-formed address is answer enough) would claim every EVM wallet for the
  # C-Chain and turn each one's detection into a question. Only the AVAX balance
  # is ever read here, so a zero balance has nothing to track, and one request
  # fits inside the detection deadline.
  def has_activity?(address)
    return false unless valid_address?(address)

    hex_to_i(detection_provider.get_balance(address)).positive?
  rescue StandardError => e
    Rails.logger.warn("Onchain::AvalancheCChainAdapter - activity probe failed: #{e.class}")
    # Not false — see Onchain::ChainAdapter#has_activity? on the third answer.
    nil
  end

  def fetch_snapshot(address)
    raise Onchain::Chains::Error, "Invalid Avalanche C-Chain address" unless valid_address?(address)

    wrap_provider_errors do
      quantity = balance_in_avax(address)

      Onchain::Snapshot.new(
        assets: [ definition.native_asset(quantity: quantity) ],
        movements: [],
        history_truncated: true
      )
    end
  end

  def provider_error_classes
    [ Provider::AvalancheCChain::RateLimitError, Provider::AvalancheCChain::Error ]
  end

  private
    attr_reader :credentials

    def definition
      Onchain::Chains.find!(Onchain::Chains::AVALANCHE_C)
    end

    def provider
      @provider ||= Provider::AvalancheCChain.new
    end

    def detection_provider
      @detection_provider ||= Provider::AvalancheCChain.new(request_timeout: Onchain::DetectionBudget.timeout)
    end

    def balance_in_avax(address)
      hex_to_i(provider.get_balance(address)).to_d / WEI_PER_AVAX
    end

    def hex_to_i(hex)
      Integer(hex, 16)
    rescue ArgumentError
      raise Provider::AvalancheCChain::ApiError, "Avalanche C-Chain node returned a non-numeric value"
    end
end
