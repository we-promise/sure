# frozen_string_literal: true

class BitcoinWalletAccount::Snapshot
  class ChangedTip < StandardError; end
  class IncompleteMempool < StandardError; end
  Result = Data.define(:balance_sats, :transactions, :block_height, :history_truncated, :used_addresses)

  # Bind the wallet to a provider without performing network
  # requests or changing the wallet's published balance.
  def initialize(wallet, provider:)
    @wallet = wallet
    @provider = provider
  end

  # Read an aggregate at a stable chain tip, following transaction references
  # only when they belong to tracked addresses. Deduplicate pending movements
  # and reject incomplete or conflicting reads before returning a Result.
  # Used-address markers are returned for publication, not persisted here.
  def fetch
    before = provider.tip_hash
    height = provider.tip_height
    # Discovery already probes the unused lookahead. Including those thousands
    # of zero-balance rows again would make a stable-tip read unfinishable.
    known = wallet.bitcoin_wallet_sources.pluck(:receive_address)
    tracked = wallet.bitcoin_wallet_addresses
    owned_addresses = tracked.pluck(:address).to_set
    read_addresses = tracked.where(used: true).or(tracked.where(bitcoin_wallet_source_id: nil))
      .or(tracked.where(address: known)).pluck(:address).to_set
    pending_addresses = read_addresses.to_a
    used_addresses = Set.new
    confirmed_sats = 0
    transactions = {}
    truncated = false

    until pending_addresses.empty?
      address = pending_addresses.shift
      summary = provider.get_address(address)
      stats = summary.fetch("chain_stats")
      confirmed_sats += Integer(stats.fetch("funded_txo_sum")) - Integer(stats.fetch("spent_txo_sum"))
      if %w[chain_stats mempool_stats].sum { |key| Integer(summary.fetch(key).fetch("tx_count")) }.positive?
        used_addresses.add(address)
      end
      address_transactions = provider.get_wallet_transactions(address, since: wallet.baseline_at,
        include_history: wallet.baseline_at.present? && Integer(stats.fetch("tx_count")).positive?,
        include_mempool: Integer(summary.fetch("mempool_stats").fetch("tx_count")).positive?)
      pending_count = address_transactions.count { |tx| tx.dig("status", "confirmed") == false }
      if pending_count != Integer(summary.fetch("mempool_stats").fetch("tx_count"))
        raise IncompleteMempool, "The mempool changed or its address history was truncated; retry the wallet"
      end
      address_transactions.each do |tx|
        transactions[tx.fetch("txid")] = tx
        observed = referenced_addresses(tx) & owned_addresses
        used_addresses.merge(observed)
        # Follow only addresses touched by observed transactions, so a pending
        # child spending newly received change is included in this same read.
        additional = observed - read_addresses
        read_addresses.merge(additional)
        pending_addresses.concat(additional.to_a)
      end
      truncated ||= provider.truncated
    end
    raise ChangedTip, "The chain advanced during the read; retry the complete wallet" unless provider.tip_hash == before

    pending = transactions.values.reject { |tx| tx.dig("status", "confirmed") }
    spent = Set.new
    pending.each do |tx|
      Array(tx["vin"]).each do |input|
        next unless input["txid"] && input.key?("vout")

        outpoint = [ input["txid"], input["vout"] ]
        raise IncompleteMempool, "Conflicting pending spends; retry the wallet" unless spent.add?(outpoint)
      end
    end
    # Ownership includes the complete tracked set, independently of the initial
    # read scope, so newly observed change cannot be treated as an external spend.
    pending_sats = pending.sum { |tx| net_sats(tx, owned_addresses) }
    raise ChangedTip, "Inconsistent address balances; retry the complete wallet" if confirmed_sats + pending_sats < 0
    Result.new(balance_sats: confirmed_sats + pending_sats, transactions: transactions.values,
      block_height: height, history_truncated: truncated, used_addresses: used_addresses)
  end

  # Return owned outputs minus owned inputs in satoshis. Internal movement nets
  # to its fee, and an exchange batch credits only this wallet's outputs.
  def self.net_sats(transaction, addresses)
    received = Array(transaction["vout"]).sum { |output| value_for(output, addresses) }
    spent = Array(transaction["vin"]).sum { |input| value_for(input["prevout"], addresses) }
    received - spent
  end

  private
    attr_reader :wallet, :provider

    # Apply the shared ownership calculation to a transaction in this read.
    def net_sats(transaction, addresses)
      self.class.net_sats(transaction, addresses)
    end

    # Collect script addresses from outputs and spent prevouts; callers must
    # intersect these untrusted provider references with tracked ownership.
    def referenced_addresses(transaction)
      outputs = Array(transaction["vout"]) + Array(transaction["vin"]).filter_map { |input| input["prevout"] }
      outputs.filter_map { |output| output["scriptpubkey_address"] }.to_set
    end

    # Read an integer output value only when its script belongs to the wallet;
    # absent coinbase prevouts and external outputs contribute zero.
    def self.value_for(output, addresses)
      return 0 unless output.is_a?(Hash) && addresses.include?(output["scriptpubkey_address"])

      Integer(output.fetch("value"))
    end
end
