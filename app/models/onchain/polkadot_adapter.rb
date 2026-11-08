# frozen_string_literal: true

# Polkadot DOT on Asset Hub: free plus reserved, so staked DOT counts. No keyless
# source indexes transfers, so only the balance is read.
class Onchain::PolkadotAdapter
  include Onchain::ChainAdapter

  PLANCK_PER_DOT = 10_000_000_000.to_d

  # SS58 with the Polkadot network prefix (0), which always starts with "1".
  # Base58: no 0, O, I or l.
  ADDRESS_PATTERN = /\A1[1-9A-HJ-NP-Za-km-z]{46,47}\z/

  def initialize(credentials: {})
    @credentials = credentials
  end

  def valid_address?(address)
    ADDRESS_PATTERN.match?(address.to_s.strip)
  end

  def fetch_snapshot(address)
    raise Onchain::Chains::Error, "Invalid Polkadot address" unless valid_address?(address)

    wrap_provider_errors do
      info = provider.balance_info(address)

      Onchain::Snapshot.new(
        assets: [ definition.native_asset(quantity: (info["free"].to_d + info["reserved"].to_d) / PLANCK_PER_DOT) ],
        movements: []
      )
    rescue Provider::PolkadotSidecar::InvalidAddressError
      raise Onchain::Chains::Error, "Invalid Polkadot address"
    end
  end

  def provider_error_classes
    [ Provider::PolkadotSidecar::RateLimitError, Provider::PolkadotSidecar::Error ]
  end

  private
    attr_reader :credentials

    def definition
      Onchain::Chains.find!(Onchain::Chains::POLKADOT)
    end

    def provider
      @provider ||= Provider::PolkadotSidecar.new
    end
end
