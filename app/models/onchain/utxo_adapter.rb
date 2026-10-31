# frozen_string_literal: true

# Litecoin, Dogecoin and Zcash, read from a single address through SoChain.
#
# One adapter class serves all three: what makes them different — the SoChain
# network code and the address formats — is data in the chain registry.
#
# Like Bitcoin, these chains have no account balances and their wallets are
# normally HD wallets, so a single address shows only what that address holds.
# The balance includes the mempool, as Onchain::BitcoinAdapter's does. Zcash is
# read from transparent addresses (t1…, t3…) only: shielded balances are not
# visible on chain.
class Onchain::UtxoAdapter
  include Onchain::ChainAdapter

  attr_reader :chain, :sochain_network, :address_patterns, :case_insensitive_patterns

  # `case_insensitive_patterns` match bech32 addresses, which are canonically
  # lowercase; everything else is Base58 and keeps its case.
  def initialize(chain:, sochain_network:, address_patterns:, case_insensitive_patterns: [], credentials: {})
    @chain = chain.to_s
    @sochain_network = sochain_network
    @address_patterns = address_patterns
    @case_insensitive_patterns = case_insensitive_patterns
    @credentials = credentials
  end

  def valid_address?(address)
    candidate = address.to_s.strip
    address_patterns.any? { |pattern| pattern.match?(candidate) } || bech32?(candidate)
  end

  def canonical_address(address)
    candidate = address.to_s.strip
    bech32?(candidate) ? candidate.downcase : candidate
  end

  # One request. Litecoin's legacy "3…" script addresses share Bitcoin's shape
  # and Dogecoin's share Solana's Base58 alphabet, so detection asks.
  def has_activity?(address)
    return false unless valid_address?(address)

    detection_provider.transaction_count(canonical_address(address)).positive?
  rescue StandardError => e
    Rails.logger.warn("Onchain::UtxoAdapter(#{chain}) - activity probe failed: #{e.class}")
    # Not false — see Onchain::ChainAdapter#has_activity? on the third answer.
    nil
  end

  def fetch_snapshot(address)
    raise Onchain::Chains::Error, "Invalid #{definition.native.name} address" unless valid_address?(address)

    address = canonical_address(address)

    wrap_provider_errors do
      balance = provider.get_balance(address)
      movements = best_effort_movements { movements_for(address) }

      Onchain::Snapshot.new(
        assets: [ definition.native_asset(quantity: balance) ],
        movements: movements || [],
        history_truncated: movements.nil? || provider.truncated
      )
    end
  end

  def provider_error_classes
    [ Provider::Sochain::RateLimitError, Provider::Sochain::Error ]
  end

  private
    attr_reader :credentials

    def bech32?(candidate)
      single_case?(candidate) && case_insensitive_patterns.any? { |pattern| pattern.match?(candidate) }
    end

    def definition
      Onchain::Chains.find!(chain)
    end

    def api_key
      credentials[:sochain_api_key].presence || ENV["SOCHAIN_API_KEY"].presence
    end

    def provider
      @provider ||= Provider::Sochain.new(
        network: sochain_network,
        api_key: api_key,
        max_pages: Onchain::HistoryBudget.pages
      )
    end

    def detection_provider
      @detection_provider ||= Provider::Sochain.new(
        network: sochain_network,
        api_key: api_key,
        request_timeout: Onchain::DetectionBudget.timeout,
        max_retries: Onchain::DetectionBudget.retries
      )
    end

    # SoChain reports each transaction's net effect on the address. One that
    # only moves coins between the address and itself nets to its fee.
    def movements_for(address)
      provider.get_address_transactions(address).filter_map do |transaction|
        next if transaction[:balance_change].zero?

        Onchain::Movement.new(
          external_id: transaction[:hash],
          symbol: definition.native.symbol,
          contract: nil,
          amount: transaction[:balance_change],
          timestamp: transaction_date(transaction)
        )
      end
    end

    # Unconfirmed transactions happened now.
    def transaction_date(transaction)
      return Date.current if transaction[:block].nil? || transaction[:time].nil?

      transaction[:time].to_date
    end
end
