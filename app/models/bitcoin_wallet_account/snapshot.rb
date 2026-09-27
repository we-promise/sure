# frozen_string_literal: true

class BitcoinWalletAccount::Snapshot
  class ChangedTip < StandardError; end
  class IncompleteMempool < StandardError; end
  Result = Data.define(:balance_sats, :transactions, :block_height, :history_truncated)

  def initialize(wallet, provider:)
    @wallet = wallet
    @provider = provider
  end

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
    confirmed_sats = 0
    transactions = {}
    truncated = false

    read_addresses.each do |address|
      summary = provider.get_address(address)
      stats = summary.fetch("chain_stats")
      confirmed_sats += Integer(stats.fetch("funded_txo_sum")) - Integer(stats.fetch("spent_txo_sum"))
      address_transactions = provider.get_wallet_transactions(address, since: wallet.baseline_at,
        include_history: wallet.baseline_at.present? && Integer(stats.fetch("tx_count")).positive?,
        include_mempool: Integer(summary.fetch("mempool_stats").fetch("tx_count")).positive?)
      pending_count = address_transactions.count { |tx| tx.dig("status", "confirmed") == false }
      if pending_count != Integer(summary.fetch("mempool_stats").fetch("tx_count"))
        raise IncompleteMempool, "The mempool changed or its address history was truncated; retry the wallet"
      end
      address_transactions.each do |tx|
        transactions[tx.fetch("txid")] = tx
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
    # Change may arrive after discovery checked a lookahead address. It still
    # belongs to this wallet even when that address does not need another read.
    pending_sats = pending.sum { |tx| net_sats(tx, owned_addresses) }
    raise ChangedTip, "Inconsistent address balances; retry the complete wallet" if confirmed_sats + pending_sats < 0
    Result.new(balance_sats: confirmed_sats + pending_sats, transactions: transactions.values,
      block_height: height, history_truncated: truncated)
  end

  def self.net_sats(transaction, addresses)
    received = Array(transaction["vout"]).sum { |output| value_for(output, addresses) }
    spent = Array(transaction["vin"]).sum { |input| value_for(input["prevout"], addresses) }
    received - spent
  end

  private
    attr_reader :wallet, :provider

    def net_sats(transaction, addresses)
      self.class.net_sats(transaction, addresses)
    end

    def self.value_for(output, addresses)
      return 0 unless output.is_a?(Hash) && addresses.include?(output["scriptpubkey_address"])

      Integer(output.fetch("value"))
    end
end
