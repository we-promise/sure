# frozen_string_literal: true

class BitcoinWalletAccount::Snapshot
  class ChangedTip < StandardError; end
  class IncompleteMempool < StandardError; end
  Result = Data.define(:balance_sats, :transactions, :block_height, :history_truncated, :used_addresses, :block_hash, :missing_statuses)

  # Bind the wallet to a provider without performing network
  # requests or changing the wallet's published balance.
  def initialize(wallet, provider:)
    @wallet = wallet
    @provider = provider
  end

  # Reconcile a normal chain extension by rereading only addresses affected by
  # its blocks. Include older HD checkpoints so a deposit during another job
  # cannot be missed by the final read.
  def fetch(before: provider.tip_hash, discovery_tips: [])
    known = wallet.bitcoin_wallet_sources.pluck(:receive_address)
    tracked = wallet.bitcoin_wallet_addresses
    owned_addresses = tracked.pluck(:address).to_set
    read_addresses = tracked.where(used: true).or(tracked.where(bitcoin_wallet_source_id: nil))
      .or(tracked.where(address: known)).pluck(:address).to_set
    pending_addresses = read_addresses.dup
    chain = BitcoinWalletAccount::ChainWindow.new(provider, owned_addresses)
    height = chain.height(before)
    observations = {}
    errors = {}
    advances = 0
    late_discovery_addresses = Set.new
    missing_statuses = {}
    tip = before
    discovery_tips = discovery_tips.uniq

    loop do
      until pending_addresses.empty?
        address = pending_addresses.first
        pending_addresses.delete(address)
        begin
          observations[address] = read_address(address)
          errors.delete(address)
        rescue IncompleteMempool => error
          observations.delete(address)
          errors[address] = error
          next
        end
        observed = observations[address][:transactions].each_with_object(Set.new) do |tx, addresses|
          addresses.merge(self.class.referenced_addresses(tx))
        end & owned_addresses
        pending_addresses.merge(observed - read_addresses)
        read_addresses.merge(observed)
      end

      if block_given?
        observed_ids = observations.values.flat_map { |row| row[:transactions].map { |tx| tx.fetch("txid") } }.uniq
        missing_statuses = yield(observed_ids, height)
      end
      after = provider.tip_hash
      break if after == tip && discovery_tips.all? { |anchor| anchor == after }

      advances += 1
      if advances > BitcoinWalletAccount::ChainWindow::MAX_BLOCKS
        raise ChangedTip, "The wallet's chain window kept moving"
      end

      dirty = chain.changed_addresses(from: tip, to: after)
      if after != tip
        dirty.merge(errors.keys)
        # A new block can evict a wallet payment by spending an external input.
        observations.each do |address, observation|
          dirty.add(address) if observation[:transactions].any? { |tx| tx.dig("status", "confirmed") == false }
        end
      end
      late = discovery_tips.each_with_object(Set.new) do |anchor, addresses|
        addresses.merge(chain.changed_addresses(from: anchor, to: after))
      end
      pending_addresses.merge(dirty).merge(late - read_addresses)
      read_addresses.merge(pending_addresses)
      late_discovery_addresses.merge(late)
      height = chain.height(after) if after != tip
      tip = after
      discovery_tips = [ tip ] if discovery_tips.present?
    end

    raise errors.values.first if errors.present?

    if missing_statuses.values.any? { |status| status && status["confirmed"] && status["block_height"].to_i > height }
      raise ChangedTip, "A transaction confirmed after the wallet read"
    end

    confirmed_sats = observations.values.sum { |row| row[:confirmed_sats] }
    used_addresses = late_discovery_addresses.dup
    transactions = {}
    observations.each do |address, observation|
      used_addresses.add(address) if observation[:used]
      observation[:transactions].each do |tx|
        txid = tx.fetch("txid")
        prior = transactions[txid]
        if prior && prior.fetch("status").slice("confirmed", "block_hash") != tx.fetch("status").slice("confirmed", "block_hash")
          raise IncompleteMempool, "Conflicting transaction statuses; retry the wallet"
        end
        transactions[txid] = tx
        used_addresses.merge(self.class.referenced_addresses(tx) & owned_addresses)
      end
    end

    pending = transactions.values.reject { |tx| tx.dig("status", "confirmed") }
    pending_ids = observations.transform_values do |observation|
      observation[:transactions].filter_map { |tx| tx["txid"] if tx.dig("status", "confirmed") == false }.to_set
    end
    pending.each do |tx|
      referenced = self.class.referenced_addresses(tx) & owned_addresses
      unless referenced.all? { |address| pending_ids.fetch(address).include?(tx.fetch("txid")) }
        raise IncompleteMempool, "Incomplete cross-address pending transaction; retry the wallet"
      end
    end
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
      block_height: height, history_truncated: observations.values.any? { |row| row[:truncated] },
      used_addresses: used_addresses, block_hash: tip, missing_statuses: missing_statuses)
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

    def read_address(address)
      summary = provider.get_address(address)
      stats = summary.fetch("chain_stats")
      confirmed_count = Integer(stats.fetch("tx_count"))
      mempool_count = Integer(summary.fetch("mempool_stats").fetch("tx_count"))
      transactions = provider.get_wallet_transactions(address, since: wallet.baseline_at,
        include_history: wallet.baseline_at.present? && confirmed_count.positive?, include_mempool: mempool_count.positive?)
      if transactions.count { |tx| tx.dig("status", "confirmed") == false } != mempool_count
        raise IncompleteMempool, "The mempool changed or its address history was truncated; retry the wallet"
      end

      { confirmed_sats: Integer(stats.fetch("funded_txo_sum")) - Integer(stats.fetch("spent_txo_sum")),
        used: (confirmed_count + mempool_count).positive?, transactions: transactions, truncated: provider.truncated }
    end

    def self.referenced_addresses(transaction)
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
