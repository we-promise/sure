# frozen_string_literal: true

# Bitcoin, read from a single address.
#
# Bitcoin has no account balances: an address owns unspent outputs, so the
# balance is everything ever paid to it minus everything spent from it. Mempool
# totals are included, because a spend that is broadcast but unconfirmed has
# already left the wallet as far as the owner is concerned.
#
# Single address only, by design. A Bitcoin wallet is normally an HD wallet: one
# extended key (xpub/ypub/zpub) derives thousands of addresses and change is
# sent to derived ones, so tracking a single address under-reports the balance
# of such a wallet. Supporting extended keys needs either BIP32 derivation — a
# new dependency this codebase does not want — or a backend that indexes
# descriptors. The linking UI states this limit rather than burying it in docs.
class Onchain::BitcoinAdapter
  include Onchain::ChainAdapter

  SATS_PER_BTC = 100_000_000.to_d

  # P2PKH ("1…") and P2SH ("3…"), Base58Check: no 0, O, I or l.
  BASE58_PATTERN = /\A[13][1-9A-HJ-NP-Za-km-z]{25,39}\z/
  # Bech32 (P2WPKH/P2WSH, "bc1q…") and Bech32m (Taproot, "bc1p…"). The bech32
  # character set excludes 1, b, i and o after the separator.
  BECH32_PATTERN = /\Abc1[ac-hj-np-z02-9]{11,87}\z/i

  def initialize(credentials: {})
    @credentials = credentials
  end

  def valid_address?(address)
    candidate = address.to_s.strip
    BASE58_PATTERN.match?(candidate) || BECH32_PATTERN.match?(candidate)
  end

  # Bech32 is case-insensitive and canonically lowercase — and the API reports it
  # that way, so an uppercase input would otherwise match no output and silently
  # produce zero movements. Base58 is case-sensitive and must be left alone.
  def canonical_address(address)
    candidate = address.to_s.strip
    BECH32_PATTERN.match?(candidate) ? candidate.downcase : candidate
  end

  def fetch_snapshot(address)
    raise Onchain::Chains::Error, "Invalid Bitcoin address" unless valid_address?(address)

    wrap_provider_errors do
      summary = provider.get_address(address)

      movements = best_effort_movements { movements_for(address) }

      Onchain::Snapshot.new(
        assets: [ definition.native_asset(quantity: balance_from(summary)) ],
        movements: movements || [],
        history_truncated: movements.nil? || provider.truncated
      )
    end
  end

  def provider_error_classes
    [ Provider::MempoolSpace::RateLimitError, Provider::MempoolSpace::Error ]
  end

  private
    attr_reader :credentials

    def definition
      Onchain::Chains.find!(Onchain::Chains::BITCOIN)
    end

    def provider
      @provider ||= Provider::MempoolSpace.new(max_pages: Onchain::HistoryBudget.pages)
    end

    # Confirmed plus mempool: funded minus spent.
    def balance_from(summary)
      sats = %w[chain_stats mempool_stats].sum do |scope|
        stats = summary.to_h.fetch(scope, {}).to_h
        stats.fetch("funded_txo_sum", 0).to_d - stats.fetch("spent_txo_sum", 0).to_d
      end

      sats / SATS_PER_BTC
    end

    def movements_for(address)
      provider.get_address_transactions(address).filter_map do |transaction|
        amount = net_amount(transaction, address)
        next if amount.zero?

        Onchain::Movement.new(
          external_id: transaction["txid"],
          symbol: definition.native.symbol,
          contract: nil,
          amount: amount,
          timestamp: transaction_date(transaction)
        )
      end
    end

    # What the address gained or lost in this transaction: outputs paid to it
    # minus the inputs it funded. A transaction that only moves coins between
    # the address and itself nets to zero and is dropped.
    def net_amount(transaction, address)
      received = Array(transaction["vout"]).sum { |output| value_for(output, address) }
      sent = Array(transaction["vin"]).sum { |input| value_for(input["prevout"], address) }

      (received - sent) / SATS_PER_BTC
    end

    def value_for(output, address)
      return 0.to_d unless output.is_a?(Hash)
      return 0.to_d unless output["scriptpubkey_address"].to_s == address.to_s

      output["value"].to_d
    end

    # Unconfirmed transactions have no block time; they happened now.
    def transaction_date(transaction)
      block_time = transaction.dig("status", "block_time")
      return Date.current if block_time.blank?

      Time.zone.at(block_time.to_i).to_date
    end
end
