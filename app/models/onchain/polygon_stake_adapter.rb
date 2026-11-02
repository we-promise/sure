# frozen_string_literal: true

# A wallet's native POL staked with Polygon validators, read from Polygon's
# own staking API (see Provider::PolygonStakingApi) — not reachable through
# the existing `polygon` chain (Onchain::EvmAdapter), since staking happens
# on Ethereum L1, not the Polygon PoS chain that adapter reads.
#
# Unlike the P-Chain/Solana-stake adapters, this one *is* keyed by a normal
# wallet address (0x..., 40 hex chars) - Polygon's staking API already does
# the "every validator this address delegated to" lookup server-side, so
# there's no equivalent of the getProgramAccounts wall Solana staking hit.
#
# No token concept applies (the API reports one staked-POL figure), so only
# a native quantity is reported, same as the P-Chain/Solana-stake adapters.
# History: the staking API has no per-delegation-event endpoint, so
# movements are not implemented - balance only, same degrade path.
class Onchain::PolygonStakeAdapter
  include Onchain::ChainAdapter

  WEI_PER_POL = BigDecimal("1e18")

  # A 0x address is valid on every EVM network, which is exactly why
  # Onchain::EvmAdapter's own has_activity? probes rather than assumes - the
  # same reasoning applies here against the existing `polygon` chain (and
  # every other EVM chain in the registry), so this overrides has_activity?
  # too instead of leaving the default valid_address?-only answer.
  ADDRESS_PATTERN = /\A0x[0-9a-fA-F]{40}\z/

  def initialize(credentials: {})
    @credentials = credentials
  end

  def valid_address?(address)
    ADDRESS_PATTERN.match?(address.to_s.strip)
  end

  # Hex has no case identity - see Onchain::EvmAdapter's own canonical_address.
  def canonical_address(address)
    address.to_s.strip.downcase
  end

  # One request, on the request thread, same contract as every other
  # has_activity? override in this app (Onchain::EvmAdapter,
  # Onchain::SolanaStakeAdapter).
  def has_activity?(address)
    return false unless valid_address?(address)

    total_staked(address, detection_provider).positive?
  rescue StandardError => e
    Rails.logger.warn("Onchain::PolygonStakeAdapter - activity probe failed: #{e.class}")
    nil
  end

  def fetch_snapshot(address)
    raise Onchain::Chains::Error, "Invalid address" unless valid_address?(address)

    wrap_provider_errors do
      Onchain::Snapshot.new(
        assets: [ definition.native_asset(quantity: total_staked(address)) ],
        movements: [],
        history_truncated: true
      )
    end
  end

  def provider_error_classes
    [ Provider::PolygonStakingApi::RateLimitError, Provider::PolygonStakingApi::Error ]
  end

  private
    attr_reader :credentials

    def definition
      Onchain::Chains.find!("polygon_stake")
    end

    def provider
      @provider ||= Provider::PolygonStakingApi.new
    end

    def detection_provider
      @detection_provider ||= Provider::PolygonStakingApi.new(request_timeout: Onchain::DetectionBudget.timeout)
    end

    # Summed across every validator the address delegated to - one wallet's
    # staked position is the total, not any single delegation.
    def total_staked(address, source = provider)
      source.get_delegations(address).sum { |delegation| wei(delegation["stake"]) } / WEI_PER_POL
    end

    # A missing stake must fail the sync, not read as zero.
    def wei(amount)
      raise Provider::PolygonStakingApi::ApiError, "Polygon staking API returned a malformed stake" unless amount.is_a?(String) && amount.match?(/\A\d+\z/)

      amount.to_d
    end
end
