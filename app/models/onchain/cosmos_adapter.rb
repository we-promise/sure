# frozen_string_literal: true

# Cosmos Hub ATOM: spendable, staked and unbonding. Public nodes do not index
# transactions, so only the balance is read.
class Onchain::CosmosAdapter
  include Onchain::ChainAdapter

  DENOM = "uatom"
  UATOM_PER_ATOM = 1_000_000.to_d

  # Bech32 account address: a 20-byte key (38 characters) or a 32-byte module or
  # interchain account (58). The character set excludes 1, b, i and o.
  ADDRESS_PATTERN = /\Acosmos1(?:[ac-hj-np-z02-9]{38}|[ac-hj-np-z02-9]{58})\z/i

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
    raise Onchain::Chains::Error, "Invalid Cosmos address" unless valid_address?(address)

    wrap_provider_errors do
      Onchain::Snapshot.new(
        assets: [ definition.native_asset(quantity: balance_of(address)) ],
        movements: []
      )
    rescue Provider::CosmosRest::InvalidAddressError
      raise Onchain::Chains::Error, "Invalid Cosmos address"
    end
  end

  def provider_error_classes
    [ Provider::CosmosRest::RateLimitError, Provider::CosmosRest::Error ]
  end

  private
    attr_reader :credentials

    def definition
      Onchain::Chains.find!(Onchain::Chains::COSMOS)
    end

    def provider
      @provider ||= Provider::CosmosRest.new
    end

    def balance_of(address)
      spendable = uatom(provider.balance(address, DENOM))
      staked = provider.delegations(address).sum { |delegation| uatom(delegation.dig("balance", "amount")) }
      unbonding = provider.unbonding_delegations(address).sum do |validator|
        Array(validator["entries"]).sum { |entry| uatom(entry["balance"]) }
      end

      (spendable + staked + unbonding) / UATOM_PER_ATOM
    end

    # A missing amount must fail the sync, not read as zero.
    def uatom(amount)
      raise Provider::CosmosRest::ApiError, "Cosmos REST returned a malformed amount" unless amount.is_a?(String) && amount.match?(/\A\d+\z/)

      amount.to_d
    end
end
