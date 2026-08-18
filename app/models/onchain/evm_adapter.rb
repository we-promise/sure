# frozen_string_literal: true

# Every EVM network, read through an interchangeable explorer backend.
#
# One adapter class serves all of them: the network's identity (its label,
# native coin and explorer URL) is data in the chain registry, so adding a
# network is a registry entry rather than a branch here.
#
# The unit being tracked is the (chain, address) couple. A 0x address is valid on
# every EVM network and holds different balances on each, which is why detection
# asks each candidate network whether the address is worth tracking there — one
# bounded request per network, never history — and why the user chooses when more
# than one answers yes.
class Onchain::EvmAdapter
  include Onchain::ChainAdapter

  ADDRESS_PATTERN = /\A0x[0-9a-fA-F]{40}\z/
  NATIVE_DECIMALS = 18

  attr_reader :chain, :explorer_url, :etherscan_chain_id

  def initialize(chain:, explorer_url:, etherscan_chain_id: nil, credentials: {})
    @chain = chain.to_s
    @explorer_url = explorer_url
    @etherscan_chain_id = etherscan_chain_id
    @credentials = credentials
  end

  def valid_address?(address)
    ADDRESS_PATTERN.match?(address.to_s.strip)
  end

  # Deliberately asks the keyless backend: its address summary reports token
  # holdings as well as the coin balance, so a wallet holding only ERC-20 tokens
  # is still found, and it costs exactly one request. An explorer being down
  # must not break the linking flow, so a failure means "not detected here"
  # rather than an error the user has to interpret.
  def has_activity?(address)
    return false unless valid_address?(address)

    keyless_backend.has_activity?(address)
  rescue StandardError => e
    Rails.logger.warn("Onchain::EvmAdapter(#{chain}) - activity probe failed: #{e.class}")
    false
  end

  def fetch_snapshot(address)
    raise Onchain::Chains::Error, "Invalid EVM address" unless valid_address?(address)

    wrap_provider_errors do
      backend = self.backend

      Onchain::Snapshot.new(
        assets: [ native_asset(backend, address), *token_assets(backend, address) ],
        movements: movements(backend, address)
      )
    end
  end

  def provider_error_classes
    if backend.is_a?(Provider::Etherscan)
      [ Provider::Etherscan::RateLimitError, Provider::Etherscan::Error ]
    else
      [ Provider::Blockscout::RateLimitError, Provider::Blockscout::Error ]
    end
  end

  # The backend actually used for balances and history: the keyed one when this
  # network supports it and the family configured a key, otherwise keyless.
  def backend
    etherscan_backend || keyless_backend
  end

  private
    attr_reader :credentials

    def definition
      Onchain::Chains.find!(chain)
    end

    def keyless_backend
      @keyless_backend ||= Provider::Blockscout.new(chain: chain, base_url: explorer_url)
    end

    def etherscan_backend
      return nil if etherscan_chain_id.blank?
      return nil if credentials[:etherscan_api_key].blank?

      @etherscan_backend ||= Provider::Etherscan.new(
        api_key: credentials[:etherscan_api_key],
        chain_id: etherscan_chain_id
      )
    end

    # Always present, even at zero: the native coin is what the wallet is, and a
    # wallet that spent everything still has a history worth keeping.
    def native_asset(backend, address)
      definition.native_asset(quantity: scale(backend.native_balance(address), NATIVE_DECIMALS))
    end

    def token_assets(backend, address)
      backend.token_balances(address).filter_map do |token|
        quantity = scale(token[:raw_amount], token[:decimals])
        next if quantity.zero?

        definition.token_asset(
          symbol: token[:symbol].presence || short_contract(token[:contract]),
          name: token[:name].presence || token[:symbol].presence || short_contract(token[:contract]),
          decimals: token[:decimals],
          quantity: quantity,
          contract: token[:contract]
        )
      end
    end

    def movements(backend, address)
      backend.transfers(address).filter_map do |transfer|
        next if transfer[:timestamp].blank?

        amount = scale(transfer[:raw_amount], transfer[:decimals])
        next if amount.zero?

        Onchain::Movement.new(
          external_id: transfer[:external_id],
          symbol: transfer[:symbol].presence || definition.native.symbol,
          contract: transfer[:contract],
          amount: amount,
          timestamp: transfer[:timestamp]
        )
      end
    end

    # Explorers report amounts in a token's smallest unit; decimals turn that
    # back into whole units.
    def scale(raw_amount, decimals)
      BigDecimal(raw_amount.to_s.presence || "0") / (10.to_d**decimals.to_i)
    rescue ArgumentError
      0.to_d
    end

    def short_contract(contract)
      contract.to_s.first(10)
    end
end
