# frozen_string_literal: true

# A single Ethereum beacon-chain validator, read from its own identity - not
# an execution-layer wallet address. Validators are identified by a BLS
# public key (0x + 96 hex chars - twice the length of a normal 0x + 40 hex
# EVM address, so it never collides with the `ethereum` chain or any other
# EVM network already in the registry), not a 0x + 40 hex address, which is
# why this needs its own address format entirely rather than fitting into
# Onchain::EvmAdapter. See Provider::EthereumBeaconApi for the API.
#
# No token concept applies (a validator holds only its own ETH balance), so
# only a native quantity is reported, same as the other staking adapters.
# History: the Beacon API has no per-validator transaction/reward-event
# history endpoint on a keyless public node, so movements are not
# implemented - balance only, same degrade path.
class Onchain::EthereumValidatorAdapter
  include Onchain::ChainAdapter

  GWEI_PER_ETH = 1_000_000_000.to_d

  # A BLS public key: 0x + 96 hex chars. Deliberately does not also accept a
  # bare numeric validator index as a linkable address - an index is
  # reassignable network state, not a portable identity a user should be
  # asked to save, whereas the pubkey is permanent from the deposit itself.
  # The provider still accepts either; this just narrows what this adapter
  # exposes as valid input.
  ADDRESS_PATTERN = /\A0x[0-9a-fA-F]{96}\z/

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

  def fetch_snapshot(address)
    raise Onchain::Chains::Error, "Invalid validator public key" unless valid_address?(address)

    wrap_provider_errors do
      data = provider.get_validator(address)
      raise Onchain::Chains::Error, "No validator found for this public key" if data.nil?

      quantity = data["balance"].to_d / GWEI_PER_ETH

      Onchain::Snapshot.new(
        assets: [ definition.native_asset(quantity: quantity) ],
        movements: [],
        history_truncated: true
      )
    end
  end

  def provider_error_classes
    [ [], Provider::EthereumBeaconApi::Error ]
  end

  private
    attr_reader :credentials

    def definition
      Onchain::Chains.find!("ethereum_validator")
    end

    def provider
      @provider ||= Provider::EthereumBeaconApi.new
    end
end
